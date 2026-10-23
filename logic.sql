USE market_db;
GO

-- ==========================================================================================
-- ไฟล์: logic.sql (Advanced Database Objects สำหรับระบบการจองและเช่าพื้นที่ตลาดนัด - หัวข้อ 27)
-- DBMS: Microsoft SQL Server 2019 (T-SQL) | อ้างอิงตาม Schema v0.1
-- หมายเหตุ (อ้างอิง schema.sql):
--   - utility_charges.charge_amount เป็นคอลัมน์คำนวณ (Computed Column) อ่านได้แต่เขียนไม่ได้
--     = CAST(units_used * unit_rate AS DECIMAL(18,2)) จึงอ่าน charge_amount ตรง ๆ ใน vw_market_zone_revenue
--     และใน sp_record_utility จะ INSERT เฉพาะ units_used / unit_rate (ห้าม INSERT charge_amount)
--   - payments.amount มี CHECK (amount > 0) จึงไม่บันทึกแถวที่ยอดเป็น 0 (เช่น โซนที่ deposit_percent = 0)
--   - คอลัมน์รหัส (status, utility_type, payment_type) ใช้ collation Latin1_General_100_BIN2 (ตัวพิมพ์เล็กเท่านั้น)
--     จึงตรวจค่าพารามิเตอร์แบบ case-sensitive ด้วย collation เดียวกัน เพื่อให้แจ้ง error ภาษาไทยก่อนชน CHECK
-- ประกอบด้วย:
--   1. Trigger (B8): trg_prevent_double_stall_booking
--   2. Stored Procedure (B7): sp_reserve_stall (พร้อม ACID Transaction)
--   3. Reporting View (B9): vw_market_zone_revenue
--   4. Stored Procedure: sp_record_utility (บันทึกค่าน้ำ/ค่าไฟ ใส่อัตราให้อัตโนมัติ)
--   5. Stored Procedure: sp_cancel_lease (ยกเลิกสัญญา + คืนมัดจำ ใน Transaction เดียว)
-- ==========================================================================================

-- ==========================================================================================
-- 1. Trigger (B8): trg_prevent_double_stall_booking
-- หน้าที่: ป้องกันไม่ให้แผงค้าเดียวกันถูกจองซ้ำในรอบวันตลาดเดียวกัน (ตรวจเฉพาะสัญญาที่ status = 'rented')
-- คุณสมบัติ:
--   - ทำงานแบบ AFTER INSERT, UPDATE
--   - รองรับการเพิ่ม/แก้ไขข้อมูลพร้อมกันหลายแถว (Multi-row safe)
--   - ไม่นับแถวตัวเอง (l.lease_id <> i.lease_id)
--   - แสดงข้อความแจ้งเตือนภาษาไทยแบบ Unicode (มี N นำหน้า)
-- ==========================================================================================
CREATE OR ALTER TRIGGER trg_prevent_double_stall_booking
ON leases
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN leases l ON l.stall_id = i.stall_id
                      AND l.market_day_id = i.market_day_id
                      AND l.lease_id <> i.lease_id
        WHERE i.status = 'rented'
          AND l.status = 'rented'
    )
    BEGIN
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW 50004, N'แผงค้านี้ถูกจองในรอบวันตลาดดังกล่าวไปแล้ว กรุณาเลือกแผงอื่น', 1;
    END
END;
GO

-- ==========================================================================================
-- 2. Stored Procedure (B7): sp_reserve_stall
-- หน้าที่: จองแผงค้า บันทึกสัญญาเช่า และรับชำระเงินค่าเช่าพร้อมเงินมัดจำภายใต้ ACID Transaction
-- กฎทางธุรกิจที่ตรวจสอบ:
--   1. วันตลาดต้องเปิดรับจอง (market_days.is_open = 1)
--   2. [BR2] ห้ามจองวันตลาดที่ผ่านมาแล้ว (market_date >= วันนี้)
--   3. แผงค้าต้องพร้อมใช้งาน (stalls.status = 'available')
--   4. ดึงค่าเช่า (base_rent) และเปอร์เซ็นต์มัดจำ (deposit_percent) จากโซนของแผง ณ วันทำสัญญา (Price Snapshot)
--   5. คำนวณเงินมัดจำ deposit_amount = ROUND(rent_price * deposit_percent / 100, 2)
--   6. ตรวจสอบยอดชำระเงิน (@paid_amount) ต้องไม่เป็น NULL และเท่ากับ ค่าเช่า + เงินมัดจำ พอดี หากไม่ครบให้ ROLLBACK
--   7. บันทึกสัญญาเช่าลงตาราง leases โดยตั้ง status = 'rented' (ไม่เปลี่ยน stalls.status)
--   8. บันทึกตาราง payments แยกเป็น 2 แถว ('rent' และ 'deposit')
--   9. ส่งรหัสสัญญาที่สร้างใหม่กลับทางพารามิเตอร์ @lease_id (OUTPUT)
-- ตัวอย่างการเรียกใช้ (market_day_id 46 = 2026-11-06 เป็นวันตลาดในอนาคตที่เตรียมไว้ใน data.sql):
--   DECLARE @new_id INT;
--   EXEC sp_reserve_stall @stall_id = 9, @merchant_id = 1, @market_day_id = 46, @staff_id = 4,
--        @paid_amount = 420.00, @lease_id = @new_id OUTPUT;   -- โซนอาหาร: 350 + มัดจำ 20% (70) = 420
--   SELECT @new_id AS new_lease_id;
--   (หมายเหตุ: Query 06 ไม่เปลี่ยน เพราะนับเฉพาะวันตลาดที่ผ่านมาแล้ว แต่ Query 01/02/05/07/09/10 จะมีสัญญาใหม่เพิ่มเข้ามา)
-- ตัวอย่างที่ต้องล้มเหลว (BR2): EXEC sp_reserve_stall 9, 1, 45, 4, 420.00;  -- 45 = 2026-10-11 ผ่านมาแล้ว
-- ==========================================================================================
CREATE OR ALTER PROCEDURE sp_reserve_stall
    @stall_id INT,
    @merchant_id INT,
    @market_day_id INT,
    @staff_id INT,
    @paid_amount DECIMAL(10,2),
    @lease_id INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. ตรวจสอบว่าผู้ค้าและพนักงานมีอยู่ในระบบจริง
        IF NOT EXISTS (SELECT 1 FROM merchants WHERE merchant_id = @merchant_id)
        BEGIN
            THROW 50000, N'ไม่พบรหัสผู้ค้าในระบบ กรุณาตรวจสอบข้อมูลผู้ค้า', 1;
        END

        IF NOT EXISTS (SELECT 1 FROM staff WHERE staff_id = @staff_id)
        BEGIN
            THROW 50005, N'ไม่พบรหัสพนักงานผู้ทำรายการในระบบ', 1;
        END

        -- 2. ตรวจสอบว่ารอบวันตลาดมีอยู่จริงและเปิดรับจอง (is_open = 1)
        IF NOT EXISTS (SELECT 1 FROM market_days WHERE market_day_id = @market_day_id AND is_open = 1)
        BEGIN
            THROW 50001, N'ไม่สามารถจองได้ เนื่องจากรอบวันตลาดนี้ปิดรับจองหรือไม่มีในระบบ', 1;
        END

        -- 2.1 [BR2] ห้ามจองวันตลาดที่ผ่านมาแล้ว (จองวันนี้ได้ จองย้อนหลังไม่ได้)
        IF EXISTS (
            SELECT 1 FROM market_days
            WHERE market_day_id = @market_day_id
              AND market_date < CAST(SYSDATETIME() AS DATE)
        )
        BEGIN
            THROW 50006, N'ไม่สามารถจองได้ เนื่องจากรอบวันตลาดนี้ผ่านมาแล้ว กรุณาเลือกวันตลาดตั้งแต่วันนี้เป็นต้นไป', 1;
        END

        -- 3. ตรวจสอบว่าแผงค้ามีอยู่จริงและอยู่ในสถานะพร้อมใช้งาน (status = 'available')
        IF NOT EXISTS (SELECT 1 FROM stalls WHERE stall_id = @stall_id AND status = 'available')
        BEGIN
            THROW 50002, N'ไม่สามารถจองได้ เนื่องจากแผงค้าอยู่ในสถานะปิดซ่อมบำรุงหรือไม่มีในระบบ', 1;
        END

        -- 4. ดึงราคาค่าเช่า (base_rent) และเปอร์เซ็นต์มัดจำ (deposit_percent) จากโซนของแผง
        DECLARE @rent_price DECIMAL(10,2);
        DECLARE @deposit_percent DECIMAL(5,2);
        DECLARE @deposit_amount DECIMAL(10,2);
        DECLARE @total_required DECIMAL(10,2);

        SELECT 
            @rent_price = z.base_rent,
            @deposit_percent = z.deposit_percent
        FROM stalls s
        JOIN stall_zones z ON s.zone_id = z.zone_id
        WHERE s.stall_id = @stall_id;

        SET @deposit_amount = ROUND(@rent_price * (@deposit_percent / 100.0), 2);
        SET @total_required = @rent_price + @deposit_amount;

        -- 5. ตรวจสอบยอดชำระเงิน ต้องเท่ากับ ค่าเช่า + เงินมัดจำ
        IF @paid_amount IS NULL OR @paid_amount <> @total_required
        BEGIN
            THROW 50003, N'ยอดชำระเงินไม่ถูกต้อง ต้องชำระค่าเช่าและเงินมัดจำให้ครบถ้วนตามที่โซนกำหนด', 1;
        END

        -- 6. บันทึกสัญญาเช่าลงตาราง leases (ตั้ง status = 'rented')
        -- หมายเหตุ: หากแผงถูกจองซ้ำในวันตลาดเดียวกัน Trigger trg_prevent_double_stall_booking จะตัดการทำงานและ Rollback ทันที
        DECLARE @new_lease_id INT;
        INSERT INTO leases (
            stall_id,
            merchant_id,
            market_day_id,
            staff_id,
            rent_price,
            deposit_amount,
            status,
            created_at
        )
        VALUES (
            @stall_id,
            @merchant_id,
            @market_day_id,
            @staff_id,
            @rent_price,
            @deposit_amount,
            'rented',
            SYSDATETIME()
        );

        SET @new_lease_id = SCOPE_IDENTITY();
        SET @lease_id = @new_lease_id;

        -- 7. บันทึกการชำระเงินลงตาราง payments แยกเป็น 2 แถว ('rent' และ 'deposit')
        --    payments.amount ต้อง > 0 จึงข้ามแถวที่ยอดเป็น 0 (เช่น โซนที่ตั้ง deposit_percent = 0)
        INSERT INTO payments (lease_id, staff_id, payment_type, amount, paid_at)
        SELECT @new_lease_id, @staff_id, v.payment_type, v.amount, SYSDATETIME()
        FROM (VALUES ('rent', @rent_price), ('deposit', @deposit_amount)) AS v(payment_type, amount)
        WHERE v.amount > 0;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================================================================
-- 3. Reporting View (B9): vw_market_zone_revenue
-- หน้าที่: สรุปอัตราการเช่าพื้นที่ (Occupancy Rate %) และรายได้รวมค่าเช่า + ค่าน้ำไฟแยกตามโซน
-- กฎการคำนวณ:
--   - Occupancy Rate (%) = จำนวนสัญญาที่เช่าสำเร็จ (status = 'rented') ในวันตลาดที่ผ่านมาแล้วหรือวันนี้
--                          / (จำนวนแผงที่ available ในโซน × จำนวนวันตลาดที่เปิดและ market_date <= วันนี้) * 100
--     (ไม่นับวันตลาดในอนาคต ทั้งตัวหารและตัวตั้ง เพราะยังไม่เกิดขึ้นจริง ไม่งั้น occupancy จะต่ำผิดความจริง)
--   - total_open_days = จำนวนวันตลาดที่เปิดและ market_date <= วันนี้
--   - rented_lease_count และรายได้: นับทุกสัญญาที่ status = 'rented' (รวมสัญญาจองล่วงหน้าที่จ่ายเงินแล้ว)
--   - [FIX] รวมค่าน้ำไฟจาก charge_amount แยกตามสัญญาก่อนเชื่อม (กันค่าเช่านับซ้ำ)
--           (charge_amount เป็นคอลัมน์คำนวณ อ่านได้แต่เขียนไม่ได้)
-- ==========================================================================================
CREATE OR ALTER VIEW vw_market_zone_revenue
AS
WITH ZoneStallStats AS (
    SELECT 
        z.zone_id,
        z.zone_name,
        z.base_rent,
        z.deposit_percent,
        COUNT(s.stall_id) AS total_stalls_in_zone,
        SUM(CASE WHEN s.status = 'available' THEN 1 ELSE 0 END) AS available_stalls_in_zone
    FROM stall_zones z
    LEFT JOIN stalls s ON z.zone_id = s.zone_id
    GROUP BY z.zone_id, z.zone_name, z.base_rent, z.deposit_percent
),
OpenMarketDays AS (
    SELECT COUNT(market_day_id) AS total_open_days
    FROM market_days
    WHERE is_open = 1
      AND market_date <= CAST(SYSDATETIME() AS DATE)
),
LeaseUtilityAgg AS (
    SELECT 
        lease_id,
        CAST(SUM(CASE WHEN utility_type = 'water' THEN charge_amount ELSE 0.00 END) AS DECIMAL(12,2)) AS water_cost,
        CAST(SUM(CASE WHEN utility_type = 'electricity' THEN charge_amount ELSE 0.00 END) AS DECIMAL(12,2)) AS electricity_cost,
        CAST(SUM(charge_amount) AS DECIMAL(12,2)) AS total_utility_cost
    FROM utility_charges
    GROUP BY lease_id
),
ZoneLeaseRevenue AS (
    SELECT 
        s.zone_id,
        COUNT(l.lease_id) AS rented_lease_count,
        SUM(CASE WHEN md.market_date <= CAST(SYSDATETIME() AS DATE) THEN 1 ELSE 0 END) AS rented_lease_count_to_date,
        SUM(l.rent_price) AS total_rent_revenue,
        SUM(ISNULL(u.water_cost, 0.00)) AS total_water_revenue,
        SUM(ISNULL(u.electricity_cost, 0.00)) AS total_electricity_revenue,
        SUM(ISNULL(u.total_utility_cost, 0.00)) AS total_utility_revenue
    FROM stalls s
    JOIN leases l ON s.stall_id = l.stall_id
    JOIN market_days md ON l.market_day_id = md.market_day_id
    LEFT JOIN LeaseUtilityAgg u ON l.lease_id = u.lease_id
    WHERE l.status = 'rented'
    GROUP BY s.zone_id
)
SELECT 
    zs.zone_id,
    zs.zone_name,
    zs.base_rent,
    zs.deposit_percent,
    zs.total_stalls_in_zone,
    zs.available_stalls_in_zone,
    omd.total_open_days,
    (zs.available_stalls_in_zone * omd.total_open_days) AS total_available_stall_days,
    ISNULL(zlr.rented_lease_count, 0) AS rented_lease_count,
    CAST(
        ISNULL(zlr.rented_lease_count_to_date, 0) * 100.0 
        / NULLIF(zs.available_stalls_in_zone * omd.total_open_days, 0)
        AS DECIMAL(5,2)
    ) AS occupancy_rate_pct,
    ISNULL(zlr.total_rent_revenue, 0.00) AS total_rent_revenue,
    ISNULL(zlr.total_water_revenue, 0.00) AS total_water_revenue,
    ISNULL(zlr.total_electricity_revenue, 0.00) AS total_electricity_revenue,
    ISNULL(zlr.total_utility_revenue, 0.00) AS total_utility_revenue,
    (ISNULL(zlr.total_rent_revenue, 0.00) + ISNULL(zlr.total_utility_revenue, 0.00)) AS total_zone_revenue
FROM ZoneStallStats zs
CROSS JOIN OpenMarketDays omd
LEFT JOIN ZoneLeaseRevenue zlr ON zs.zone_id = zlr.zone_id;
GO

-- ==========================================================================================
-- 4. Stored Procedure: sp_record_utility
-- หน้าที่: บันทึกค่าน้ำ/ค่าไฟของสัญญา หน้าเว็บส่งมาแค่ 3 ค่า (lease_id, utility_type, units_used)
--          ระบบใส่อัตราต่อหน่วย (unit_rate) ให้เอง: water = 18.00 บาท/หน่วย, electricity = 8.00 บาท/หน่วย
-- กฎที่ตรวจสอบ:
--   1. utility_type ต้องเป็น 'water' หรือ 'electricity' (ตัวพิมพ์เล็กเท่านั้น ตาม collation BIN2 ใน schema.sql)
--   2. units_used ต้องไม่เป็น NULL และไม่ติดลบ (ชนิด DECIMAL(8,2) ตาม schema.sql)
--   3. สัญญาต้องมีอยู่จริงและ status = 'rented' (สัญญาที่ยกเลิกแล้วบันทึกค่าน้ำไฟไม่ได้)
--   4. 1 สัญญาบันทึกค่าน้ำได้ 1 รายการ และค่าไฟได้ 1 รายการ (ตรงกับ uq_utility_charges_lease_id_utility_type)
--   5. ไม่ INSERT charge_amount เพราะเป็นคอลัมน์คำนวณ (อ่านได้แต่เขียนไม่ได้)
-- ผลลัพธ์: ส่ง charge_id กลับทาง OUTPUT และ SELECT แถวที่บันทึก (รวม charge_amount) ให้หน้าเว็บแสดงผล
-- ตัวอย่างการเรียกใช้:
--   DECLARE @cid INT;
--   EXEC sp_record_utility @lease_id = @new_id, @utility_type = 'electricity', @units_used = 120.50,
--        @charge_id = @cid OUTPUT;   -- 120.50 × 8 = 964.00 บาท
-- ==========================================================================================
CREATE OR ALTER PROCEDURE sp_record_utility
    @lease_id INT,
    @utility_type VARCHAR(12),
    @units_used DECIMAL(8,2),
    @charge_id INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. ตรวจสอบประเภทสาธารณูปโภค (case-sensitive แบบเดียวกับคอลัมน์) และกำหนดอัตราต่อหน่วยให้อัตโนมัติ
        DECLARE @unit_rate DECIMAL(8,2) =
            CASE @utility_type COLLATE Latin1_General_100_BIN2
                WHEN 'water'       THEN 18.00
                WHEN 'electricity' THEN 8.00
            END;

        IF @unit_rate IS NULL
        BEGIN
            THROW 50010, N'ประเภทสาธารณูปโภคไม่ถูกต้อง ต้องเป็น water หรือ electricity เท่านั้น', 1;
        END

        -- 2. ตรวจสอบจำนวนหน่วยที่ใช้
        IF @units_used IS NULL OR @units_used < 0
        BEGIN
            THROW 50011, N'จำนวนหน่วยที่ใช้ไม่ถูกต้อง ต้องระบุและต้องไม่ติดลบ', 1;
        END

        -- 3. ตรวจสอบว่าสัญญามีอยู่จริงและยังมีผลอยู่ (status = 'rented')
        IF NOT EXISTS (SELECT 1 FROM leases WHERE lease_id = @lease_id AND status = 'rented')
        BEGIN
            THROW 50012, N'ไม่สามารถบันทึกค่าน้ำไฟได้ เนื่องจากไม่พบสัญญาหรือสัญญาถูกยกเลิกไปแล้ว', 1;
        END

        -- 4. ตรวจสอบว่ายังไม่เคยบันทึกประเภทนี้ให้สัญญานี้ (ล็อกช่วงข้อมูลกันการบันทึกซ้ำพร้อมกัน)
        IF EXISTS (
            SELECT 1 FROM utility_charges WITH (UPDLOCK, HOLDLOCK)
            WHERE lease_id = @lease_id AND utility_type = @utility_type
        )
        BEGIN
            THROW 50013, N'สัญญานี้ได้บันทึกค่าสาธารณูปโภคประเภทนี้ไปแล้ว ไม่สามารถบันทึกซ้ำได้', 1;
        END

        -- 5. บันทึกรายการ (ไม่ใส่ charge_amount เพราะเป็นคอลัมน์คำนวณ)
        INSERT INTO utility_charges (lease_id, utility_type, units_used, unit_rate, recorded_at)
        VALUES (@lease_id, @utility_type, @units_used, @unit_rate, SYSDATETIME());

        SET @charge_id = SCOPE_IDENTITY();

        COMMIT TRANSACTION;

        -- ส่งแถวที่บันทึกกลับให้หน้าเว็บ (charge_amount อ่านได้จากคอลัมน์คำนวณ)
        SELECT charge_id, lease_id, utility_type, units_used, unit_rate, charge_amount, recorded_at
        FROM utility_charges
        WHERE charge_id = @charge_id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================================================================
-- 5. Stored Procedure: sp_cancel_lease
-- หน้าที่: ยกเลิกสัญญาเช่า และบันทึกการคืนเงินมัดจำ ภายใต้ Transaction เดียว (สำเร็จทั้งคู่หรือไม่เกิดทั้งคู่)
-- ขั้นตอน:
--   1. ตรวจสอบพนักงานผู้ทำรายการ
--   2. ล็อกแถวสัญญา (UPDLOCK) แล้วตรวจว่ามีอยู่จริงและ status = 'rented' (กันยกเลิกซ้ำ/คืนมัดจำซ้ำ)
--   3. UPDATE leases SET status = 'cancelled', cancelled_at = เวลาปัจจุบัน
--   4. INSERT payments ประเภท 'deposit_refund' จำนวนเท่ากับ leases.deposit_amount (คืนเฉพาะมัดจำ ไม่คืนค่าเช่า)
--      ถ้ามัดจำเป็น 0 จะไม่ INSERT เพราะ payments.amount มี CHECK (amount > 0)
-- ผลลัพธ์: ส่งยอดเงินที่คืนกลับทาง @refund_amount (OUTPUT)
-- ตัวอย่างการเรียกใช้:
--   DECLARE @refund DECIMAL(10,2);
--   EXEC sp_cancel_lease @lease_id = @new_id, @staff_id = 4, @refund_amount = @refund OUTPUT;
--   SELECT @refund AS refunded_deposit;   -- โซนอาหาร: คืนมัดจำ 70.00
-- ==========================================================================================
CREATE OR ALTER PROCEDURE sp_cancel_lease
    @lease_id INT,
    @staff_id INT,
    @refund_amount DECIMAL(10,2) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. ตรวจสอบพนักงานผู้ทำรายการ
        IF NOT EXISTS (SELECT 1 FROM staff WHERE staff_id = @staff_id)
        BEGIN
            THROW 50005, N'ไม่พบรหัสพนักงานผู้ทำรายการในระบบ', 1;
        END

        -- 2. ล็อกแถวสัญญาและอ่านสถานะ/ยอดมัดจำ
        DECLARE @status VARCHAR(15);
        DECLARE @deposit_amount DECIMAL(10,2);

        SELECT 
            @status = status,
            @deposit_amount = deposit_amount
        FROM leases WITH (UPDLOCK, ROWLOCK)
        WHERE lease_id = @lease_id;

        IF @status IS NULL
        BEGIN
            THROW 50020, N'ไม่พบสัญญาเช่าที่ต้องการยกเลิก', 1;
        END

        IF @status <> 'rented'
        BEGIN
            THROW 50021, N'สัญญานี้ถูกยกเลิกไปแล้ว ไม่สามารถยกเลิกหรือคืนมัดจำซ้ำได้', 1;
        END

        -- 3. เปลี่ยนสถานะสัญญาเป็นยกเลิก
        UPDATE leases
        SET status = 'cancelled',
            cancelled_at = SYSDATETIME()
        WHERE lease_id = @lease_id
          AND status = 'rented';

        IF @@ROWCOUNT <> 1
        BEGIN
            THROW 50021, N'สัญญานี้ถูกยกเลิกไปแล้ว ไม่สามารถยกเลิกหรือคืนมัดจำซ้ำได้', 1;
        END

        -- 4. บันทึกการคืนเงินมัดจำ (คืนเฉพาะมัดจำ ไม่คืนค่าเช่า; ข้ามถ้ามัดจำเป็น 0 เพราะ CHECK amount > 0)
        IF @deposit_amount > 0
        BEGIN
            INSERT INTO payments (lease_id, staff_id, payment_type, amount, paid_at)
            VALUES (@lease_id, @staff_id, 'deposit_refund', @deposit_amount, SYSDATETIME());
        END

        SET @refund_amount = @deposit_amount;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
