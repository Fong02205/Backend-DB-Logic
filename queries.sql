USE market_db;
GO

-- ==========================================================================================
-- ไฟล์: queries.sql (Complex Queries 10 ข้อ สำหรับระบบการจองและเช่าพื้นที่ตลาดนัด - หัวข้อ 27)
-- DBMS: Microsoft SQL Server 2019 (T-SQL) | อ้างอิงตาม Schema v0.1
-- หมายเหตุ: utility_charges.charge_amount เป็นคอลัมน์คำนวณ (Computed Column) อ่านได้แต่เขียนไม่ได้
--           = CAST(units_used * unit_rate AS DECIMAL(18,2)) ตาม schema.sql จึงอ่าน charge_amount ตรง ๆ ใน Query 02, 04, 05, 08
-- ==========================================================================================

-- ==========================================================================================
-- Query 01: ประวัติการจองและเช่าแผงค้าแบบละเอียด
-- หมวดหมู่: Multi-table JOIN (เชื่อม 5 ตาราง: merchants + leases + stalls + stall_zones + market_days ตาม B4 ข้อ 1)
-- การนำไปใช้ในระบบ: ใช้ในหน้าจอ "ประวัติการเช่าแผงค้า" สำหรับเจ้าหน้าที่และผู้ค้าเพื่อตรวจสอบรายละเอียดสัญญา
-- ==========================================================================================
SELECT 
    l.lease_id,
    md.market_date,
    z.zone_name,
    s.stall_code,
    m.merchant_name,
    m.phone,
    m.goods_type,
    l.rent_price,
    l.deposit_amount,
    l.status AS lease_status,
    l.created_at
FROM leases l
JOIN merchants m ON l.merchant_id = m.merchant_id
JOIN stalls s ON l.stall_id = s.stall_id
JOIN stall_zones z ON s.zone_id = z.zone_id
JOIN market_days md ON l.market_day_id = md.market_day_id
ORDER BY md.market_date DESC, s.stall_code ASC;
GO

-- ==========================================================================================
-- Query 02: รายงานสรุปค่าใช้จ่ายสุทธิรายสัญญา (ค่าเช่า + ค่าน้ำไฟ + ค่าปรับ ไม่รวมมัดจำ)
-- หมวดหมู่: Multi-table JOIN (รวมยอดค่าน้ำไฟและค่าปรับแยกเป็นรายสัญญาก่อน เพื่อป้องกันค่าเช่านับซ้ำ)
-- การนำไปใช้ในระบบ: ใช้ในหน้าจอ "ใบสรุปยอดค่าใช้จ่ายประจำสัญญา" เพื่อเรียกเก็บเงินผู้ค้าเมื่อสิ้นสุดวันตลาด
-- [FIX] ใช้ค่าน้ำไฟจาก charge_amount (คอลัมน์คำนวณ อ่านได้แต่เขียนไม่ได้)
-- ==========================================================================================
SELECT 
    l.lease_id,
    md.market_date,
    s.stall_code,
    m.merchant_name,
    l.rent_price,
    ISNULL(u.total_utility, 0.00) AS total_utility_cost,
    ISNULL(f.total_fine, 0.00) AS total_fine_amount,
    (l.rent_price + ISNULL(u.total_utility, 0.00) + ISNULL(f.total_fine, 0.00)) AS net_expense
FROM leases l
JOIN merchants m ON l.merchant_id = m.merchant_id
JOIN stalls s ON l.stall_id = s.stall_id
JOIN market_days md ON l.market_day_id = md.market_day_id
LEFT JOIN (
    SELECT lease_id, CAST(SUM(charge_amount) AS DECIMAL(12, 2)) AS total_utility
    FROM utility_charges
    GROUP BY lease_id
) u ON l.lease_id = u.lease_id
LEFT JOIN (
    SELECT lease_id, SUM(amount) AS total_fine
    FROM fine_logs
    GROUP BY lease_id
) f ON l.lease_id = f.lease_id
WHERE l.status = 'rented'
ORDER BY md.market_date DESC, l.lease_id ASC;
GO

-- ==========================================================================================
-- Query 03: รายชื่อผู้ค้าที่ถูกบันทึกค่าปรับสะสมมากกว่า 2 ครั้ง (> 2 ครั้ง)
-- หมวดหมู่: GROUP BY + HAVING
-- การนำไปใช้ในระบบ: ใช้ในหน้าจอ "รายชื่อผู้ค้าเฝ้าระวัง" สำหรับฝ่ายบริหารตลาดเพื่อติดตามผู้ค้าที่ทำผิดกฎบ่อย
-- ==========================================================================================
SELECT 
    m.merchant_id,
    m.merchant_name,
    m.phone,
    m.goods_type,
    COUNT(f.fine_id) AS violation_count,
    SUM(f.amount) AS total_fine_amount
FROM merchants m
JOIN leases l ON m.merchant_id = l.merchant_id
JOIN fine_logs f ON l.lease_id = f.lease_id
GROUP BY m.merchant_id, m.merchant_name, m.phone, m.goods_type
HAVING COUNT(f.fine_id) > 2
ORDER BY violation_count DESC, total_fine_amount DESC;
GO

-- ==========================================================================================
-- Query 04: โซนแผงค้าที่มีการใช้ไฟฟ้าเฉลี่ยต่อสัญญาเกินเกณฑ์ ในเดือนกันยายน 2569 (2026-09-01 ถึง 2026-09-30)
-- หมวดหมู่: GROUP BY + HAVING
-- การนำไปใช้ในระบบ: ใช้ในหน้ารายงาน "วิเคราะห์การใช้พลังงานรายโซน" ของฝ่ายซ่อมบำรุงและดูแลสาธารณูปโภค
-- (หมายเหตุ: ใช้เกณฑ์เริ่มต้นตาม B4 ข้อ 4 คือ > 100 หน่วย เมื่อรันกับ data.sql จะได้ 3 โซน (โซน 1, 2, 3) อยู่ในช่วง 3-10 แถว)
-- [FIX] ใช้รายได้ค่าไฟจาก charge_amount (คอลัมน์คำนวณ อ่านได้แต่เขียนไม่ได้)
--       (UNIQUE (lease_id, utility_type) ทำให้ 1 สัญญามีบิลไฟ 1 รายการ ค่าเฉลี่ยต่อบิล = ต่อสัญญา)
-- ==========================================================================================
SELECT 
    z.zone_id,
    z.zone_name,
    COUNT(u.charge_id) AS electricity_bill_count,
    AVG(u.units_used) AS avg_electricity_units,
    CAST(SUM(u.charge_amount) AS DECIMAL(12, 2)) AS total_electricity_revenue
FROM stall_zones z
JOIN stalls s ON z.zone_id = s.zone_id
JOIN leases l ON s.stall_id = l.stall_id
JOIN market_days md ON l.market_day_id = md.market_day_id
JOIN utility_charges u ON l.lease_id = u.lease_id
WHERE l.status = 'rented'
  AND u.utility_type = 'electricity'
  AND md.market_date BETWEEN '2026-09-01' AND '2026-09-30'
GROUP BY z.zone_id, z.zone_name
HAVING AVG(u.units_used) > 100
ORDER BY avg_electricity_units DESC;
GO

-- ==========================================================================================
-- Query 05: รอบวันตลาดที่มียอดรายรับรวมจากค่าเช่าและค่าน้ำไฟสูงเกินเกณฑ์ที่กำหนด
-- หมวดหมู่: GROUP BY + HAVING (รวมยอดค่าน้ำไฟรายสัญญาก่อนเชื่อม เพื่อไม่ให้ค่าเช่าถูกนับซ้ำ)
-- การนำไปใช้ในระบบ: ใช้ในหน้ารายงานผู้บริหาร "สรุปรอบวันตลาดที่ทำรายได้สูง (Peak Market Days)"
-- (หมายเหตุ: ปรับเกณฑ์เป็น > 20000 บาท เมื่อรันกับ data.sql จะได้ผลลัพธ์ 6 แถว ตามเกณฑ์ 3-10 แถว)
-- [FIX] ใช้ค่าน้ำไฟจาก charge_amount (คอลัมน์คำนวณ อ่านได้แต่เขียนไม่ได้)
-- ==========================================================================================
SELECT 
    md.market_day_id,
    md.market_date,
    COUNT(l.lease_id) AS rented_stall_count,
    SUM(l.rent_price) AS total_rent_revenue,
    SUM(ISNULL(u.lease_utility_cost, 0.00)) AS total_utility_revenue,
    SUM(l.rent_price + ISNULL(u.lease_utility_cost, 0.00)) AS total_day_revenue
FROM market_days md
JOIN leases l ON md.market_day_id = l.market_day_id
LEFT JOIN (
    SELECT lease_id, CAST(SUM(charge_amount) AS DECIMAL(12, 2)) AS lease_utility_cost
    FROM utility_charges
    GROUP BY lease_id
) u ON l.lease_id = u.lease_id
WHERE l.status = 'rented'
GROUP BY md.market_day_id, md.market_date
HAVING SUM(l.rent_price + ISNULL(u.lease_utility_cost, 0.00)) > 20000
ORDER BY total_day_revenue DESC;
GO

-- ==========================================================================================
-- Query 06: แผงค้าที่ไม่เคยถูกเช่าเลยในรอบวันตลาดที่ผ่านมาแล้ว 5 รอบล่าสุด
-- หมวดหมู่: Subquery (นับเฉพาะสัญญา status = 'rented' และใช้เฉพาะรอบวันตลาดที่ผ่านมาแล้ว)
-- การนำไปใช้ในระบบ: ใช้ในหน้าจอ "วิเคราะห์แผงค้าว่างต่อเนื่อง" เพื่อจัดโปรโมชั่นลดราคาค่าเช่าดึงดูดผู้ค้า
-- (หมายเหตุ: ใช้วันที่ปัจจุบันจาก SYSDATETIME() เมื่อรันกับ data.sql ตั้งแต่วันที่ 28 ก.ย. 2569 เป็นต้นไป
--  จะได้ 5 แผงเสมอ คือ F09, B09, S09, C09 และ G09 (stall_id 9, 19, 29, 39, 49)
--  วันตลาดในอนาคต (พ.ย.-ธ.ค. 2569) ไม่ถูกนับ เพราะกรอง market_date < วันนี้
--  ถ้าต้องการให้ผลลัพธ์คงที่ ให้เปลี่ยน CAST(SYSDATETIME() AS DATE) เป็น '2026-10-01' ตามที่ B4 ข้อ 6 อนุญาต)
-- ==========================================================================================
SELECT 
    s.stall_id,
    s.stall_code,
    z.zone_name,
    s.size_sqm,
    z.base_rent,
    s.status AS stall_physical_status
FROM stalls s
JOIN stall_zones z ON s.zone_id = z.zone_id
WHERE s.status = 'available'
  AND s.stall_id NOT IN (
      SELECT l.stall_id
      FROM leases l
      WHERE l.status = 'rented'
        AND l.market_day_id IN (
            SELECT TOP 5 md.market_day_id
            FROM market_days md
            WHERE md.is_open = 1
              AND md.market_date < CAST(SYSDATETIME() AS DATE)
            ORDER BY md.market_date DESC
        )
  )
ORDER BY z.zone_name ASC, s.stall_code ASC;
GO

-- ==========================================================================================
-- Query 07: ผู้ค้าที่มียอดชำระเงินรวมสูงกว่าค่าเฉลี่ยของผู้ค้าทั้งหมด (นับเฉพาะเงินจ่ายเข้า ไม่รวมคืนมัดจำ)
-- หมวดหมู่: Subquery (กรอง payment_type <> 'deposit_refund')
-- การนำไปใช้ในระบบ: ใช้ในหน้าจอ "รายชื่อผู้ค้าระดับ VIP" เพื่อมอบสิทธิ์จองพื้นที่แผงค้าก่อนในรอบถัดไป
-- ==========================================================================================
SELECT 
    m.merchant_id,
    m.merchant_name,
    m.phone,
    m.goods_type,
    SUM(p.amount) AS total_paid_amount
FROM merchants m
JOIN leases l ON m.merchant_id = l.merchant_id
JOIN payments p ON l.lease_id = p.lease_id
WHERE p.payment_type <> 'deposit_refund'
GROUP BY m.merchant_id, m.merchant_name, m.phone, m.goods_type
HAVING SUM(p.amount) > (
    SELECT AVG(merchant_total.sum_paid)
    FROM (
        SELECT l2.merchant_id, SUM(p2.amount) AS sum_paid
        FROM leases l2
        JOIN payments p2 ON l2.lease_id = p2.lease_id
        WHERE p2.payment_type <> 'deposit_refund'
        GROUP BY l2.merchant_id
    ) AS merchant_total
)
ORDER BY total_paid_amount DESC;
GO

-- ==========================================================================================
-- Query 08: สัญญาเช่าที่มียอดค่าน้ำไฟรวมสูงกว่าค่าเฉลี่ยค่าน้ำไฟต่อสัญญาของโซนเดียวกัน
-- หมวดหมู่: Correlated Subquery (เปรียบเทียบยอดค่าน้ำไฟกับค่าเฉลี่ยภายใน zone_id เดียวกัน)
-- การนำไปใช้ในระบบ: ใช้ในหน้าจอ "แจ้งเตือนการใช้สาธารณูปโภคสูงผิดปกติ" เพื่อให้เจ้าหน้าที่ตรวจสอบมิเตอร์
-- [FIX] ใช้ค่าน้ำไฟจาก charge_amount (คอลัมน์คำนวณ อ่านได้แต่เขียนไม่ได้)
-- ==========================================================================================
WITH LeaseUtility AS (
    SELECT 
        l.lease_id,
        s.zone_id,
        s.stall_code,
        m.merchant_name,
        md.market_date,
        CAST(SUM(u.charge_amount) AS DECIMAL(12, 2)) AS total_utility_cost
    FROM leases l
    JOIN stalls s ON l.stall_id = s.stall_id
    JOIN merchants m ON l.merchant_id = m.merchant_id
    JOIN market_days md ON l.market_day_id = md.market_day_id
    JOIN utility_charges u ON l.lease_id = u.lease_id
    WHERE l.status = 'rented'
    GROUP BY l.lease_id, s.zone_id, s.stall_code, m.merchant_name, md.market_date
)
SELECT 
    lu.lease_id,
    z.zone_name,
    lu.stall_code,
    lu.merchant_name,
    lu.market_date,
    lu.total_utility_cost
FROM LeaseUtility lu
JOIN stall_zones z ON lu.zone_id = z.zone_id
WHERE lu.total_utility_cost > (
    SELECT AVG(lu_inner.total_utility_cost)
    FROM LeaseUtility lu_inner
    WHERE lu_inner.zone_id = lu.zone_id
)
ORDER BY z.zone_name ASC, lu.total_utility_cost DESC;
GO

-- ==========================================================================================
-- Query 09: จัดอันดับแผงค้าที่ทำรายได้ค่าเช่าสะสมสูงสุดในแต่ละโซน (นับเฉพาะสัญญา status = 'rented')
-- หมวดหมู่: Window Function (DENSE_RANK() OVER PARTITION BY zone_id)
-- การนำไปใช้ในระบบ: ใช้ในหน้าแดชบอร์ด "อันดับแผงค้าทำเงินประจำโซน" สำหรับประเมินราคาพื้นที่
-- ==========================================================================================
SELECT 
    z.zone_id,
    z.zone_name,
    s.stall_id,
    s.stall_code,
    COUNT(l.lease_id) AS total_rented_times,
    SUM(l.rent_price) AS total_rent_revenue,
    DENSE_RANK() OVER (
        PARTITION BY z.zone_id 
        ORDER BY SUM(l.rent_price) DESC
    ) AS revenue_rank_in_zone
FROM stall_zones z
JOIN stalls s ON z.zone_id = s.zone_id
JOIN leases l ON s.stall_id = l.stall_id
WHERE l.status = 'rented'
GROUP BY z.zone_id, z.zone_name, s.stall_id, s.stall_code
ORDER BY z.zone_id ASC, revenue_rank_in_zone ASC;
GO

-- ==========================================================================================
-- Query 10: รายได้ค่าเช่ารายวันและยอดรายได้ค่าเช่าสะสมตามลำดับวันตลาด (Running Total)
-- หมวดหมู่: Window Function (SUM() OVER ORDER BY market_date นับเฉพาะสัญญา status = 'rented')
-- การนำไปใช้ในระบบ: ใช้แสดงกราฟ "แนวโน้มรายได้ค่าเช่าสะสมของตลาด" บนหน้าแดชบอร์ดผู้บริหาร
-- ==========================================================================================
SELECT 
    md.market_day_id,
    md.market_date,
    COUNT(l.lease_id) AS active_leases_count,
    SUM(l.rent_price) AS daily_rent_revenue,
    SUM(SUM(l.rent_price)) OVER (
        ORDER BY md.market_date ASC
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS cumulative_rent_revenue
FROM market_days md
JOIN leases l ON md.market_day_id = l.market_day_id
WHERE l.status = 'rented'
GROUP BY md.market_day_id, md.market_date
ORDER BY md.market_date ASC;
GO