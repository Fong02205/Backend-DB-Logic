-- ==========================================================================================
-- ไฟล์: logic.sql (Advanced Database Objects สำหรับระบบการจองและเช่าพื้นที่ตลาดนัด - หัวข้อ 27)
-- DBMS: Microsoft SQL Server 2019 (T-SQL) | อ้างอิงตาม Schema v0.1
-- หมายเหตุ: ใน Schema v0.1 ไม่เก็บ utility_charges.charge_amount แล้ว (คำนวณตอนอ่าน)
--           จึงใช้ units_used * unit_rate แทนใน vw_market_zone_revenue
-- ประกอบด้วย:
--   1. Trigger (B8): trg_prevent_double_stall_booking
--   2. Stored Procedure (B7): sp_reserve_stall (พร้อม ACID Transaction)
--   3. Reporting View (B9): vw_market_zone_revenue
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
--   2. แผงค้าต้องพร้อมใช้งาน (stalls.status = 'available')
--   3. ดึงค่าเช่า (base_rent) และเปอร์เซ็นต์มัดจำ (deposit_percent) จากโซนของแผง ณ วันทำสัญญา (Price Snapshot)
--   4. คำนวณเงินมัดจำ deposit_amount = ROUND(rent_price * deposit_percent / 100, 2)
--   5. ตรวจสอบยอดชำระเงิน (@paid_amount) ต้องไม่เป็น NULL และเท่ากับ ค่าเช่า + เงินมัดจำ พอดี หากไม่ครบให้ ROLLBACK
--   6. บันทึกสัญญาเช่าลงตาราง leases โดยตั้ง status = 'rented' (ไม่เปลี่ยน stalls.status)
--   7. บันทึกตาราง payments แยกเป็น 2 แถว ('rent' และ 'deposit')
--   8. ส่งรหัสสัญญาที่สร้างใหม่กลับทางพารามิเตอร์ @lease_id (OUTPUT)
-- ตัวอย่างการเรียกใช้:
--   DECLARE @new_id INT;
--   EXEC sp_reserve_stall @stall_id = 9, @merchant_id = 1, @market_day_id = 45, @staff_id = 4,
--        @paid_amount = 420.00, @lease_id = @new_id OUTPUT;   -- โซนอาหาร: 350 + มัดจำ 20% (70) = 420
--   (หมายเหตุ: การรันตัวอย่างนี้กับ data.sql จะเพิ่มสัญญาใหม่จริง ซึ่งทำให้ผลของ Query 06 เปลี่ยนไป)
--   SELECT @new_id AS new_lease_id;
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
        INSERT INTO payments (lease_id, staff_id, payment_type, amount, paid_at)
        VALUES 
            (@new_lease_id, @staff_id, 'rent', @rent_price, SYSDATETIME()),
            (@new_lease_id, @staff_id, 'deposit', @deposit_amount, SYSDATETIME());

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
--   - Occupancy Rate (%) = จำนวนสัญญาที่เช่าสำเร็จ (status = 'rented')
--                          / (จำนวนแผงที่ available ในโซน × จำนวนวันตลาดที่เปิดทั้งหมด) * 100
--   - รายได้ค่าเช่าและค่าน้ำไฟ: นับเฉพาะสัญญาที่ status = 'rented'
--   - [FIX] คำนวณค่าน้ำไฟจาก units_used * unit_rate แยกตามสัญญาก่อนเชื่อม (ไม่มีคอลัมน์ charge_amount ใน Schema v0.1)
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
),
LeaseUtilityAgg AS (
    SELECT 
        lease_id,
        CAST(SUM(CASE WHEN utility_type = 'water' THEN units_used * unit_rate ELSE 0.00 END) AS DECIMAL(12,2)) AS water_cost,
        CAST(SUM(CASE WHEN utility_type = 'electricity' THEN units_used * unit_rate ELSE 0.00 END) AS DECIMAL(12,2)) AS electricity_cost,
        CAST(SUM(units_used * unit_rate) AS DECIMAL(12,2)) AS total_utility_cost
    FROM utility_charges
    GROUP BY lease_id
),
ZoneLeaseRevenue AS (
    SELECT 
        s.zone_id,
        COUNT(l.lease_id) AS rented_lease_count,
        SUM(l.rent_price) AS total_rent_revenue,
        SUM(ISNULL(u.water_cost, 0.00)) AS total_water_revenue,
        SUM(ISNULL(u.electricity_cost, 0.00)) AS total_electricity_revenue,
        SUM(ISNULL(u.total_utility_cost, 0.00)) AS total_utility_revenue
    FROM stalls s
    JOIN leases l ON s.stall_id = l.stall_id
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
        ISNULL(zlr.rented_lease_count, 0) * 100.0 
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