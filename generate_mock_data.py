import random
from datetime import datetime, timedelta
import os

def generate_market_data(output_path="data.sql"):
    random.seed(42)
    sql = []
    sql.append("USE market_db;")
    sql.append("GO\n")
    sql.append("-- ========================================================================================")
    sql.append("-- ไฟล์: data.sql (ชุดข้อมูลจำลอง Mock Data สำหรับระบบการจองและเช่าพื้นที่ตลาดนัด - หัวข้อ 27)")
    sql.append("-- DBMS: Microsoft SQL Server (T-SQL) | อ้างอิงตาม Schema v0.1")
    sql.append("-- ข้อกำหนด:")
    sql.append("--   1. ตารางหลัก (leases, utility_charges, payments) มีมากกว่า 500 แถว")
    sql.append("--   2. ตารางประกอบ (stalls, merchants, market_days, staff, fine_logs) มี 20-50 แถว")
    sql.append("--   3. ตาราง payments ไม่มีคอลัมน์ fine_id (ใช้ payment_type = 'fine' คู่กับ lease_id)")
    sql.append("--   4. ตาราง utility_charges ไม่ INSERT คอลัมน์คำนวณ charge_amount")
    sql.append("--   5. สัญญาที่ยกเลิก (cancelled) มีการบันทึกคืนเฉพาะมัดจำ (deposit_refund) ไม่คืนค่าเช่า")
    sql.append("-- ========================================================================================\n")
    sql.append("SET NOCOUNT ON;\n")

    # ----------------------------------------------------
    # 1. stall_zones (5 โซน)
    # ----------------------------------------------------
    zones = [
        (1, 'โซนอาหารปรุงสุก (Food Zone)', 350.00, 20.00),
        (2, 'โซนเครื่องดื่มและเบเกอรี่ (Beverage & Bakery)', 300.00, 20.00),
        (3, 'โซนอาหารสดและแช่เย็น (Fresh & Chilled)', 320.00, 25.00),
        (4, 'โซนเสื้อผ้าแฟชั่น (Fashion Zone)', 250.00, 15.00),
        (5, 'โซนสินค้าทั่วไปและเบ็ดเตล็ด (General Zone)', 200.00, 10.00)
    ]
    sql.append("-- ========================================================================================")
    sql.append("-- 1. ตาราง stall_zones (5 แถว)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT stall_zones ON;")
    for zid, name, rent, dep in zones:
        sql.append(
            f"INSERT INTO stall_zones (zone_id, zone_name, base_rent, deposit_percent) "
            f"VALUES ({zid}, N'{name}', {rent:.2f}, {dep:.2f});"
        )
    sql.append("SET IDENTITY_INSERT stall_zones OFF;\nGO\n")

    # ----------------------------------------------------
    # 2. stalls (50 แผง: โซนละ 10 แผง)
    # ----------------------------------------------------
    stalls = []  # (stall_id, zone_id, stall_code, size_sqm, status)
    stall_id_counter = 1
    zone_prefixes = {1: 'F', 2: 'B', 3: 'S', 4: 'C', 5: 'G'}
    zone_sizes = {1: 9.00, 2: 6.00, 3: 9.00, 4: 6.00, 5: 4.50}

    sql.append("-- ========================================================================================")
    sql.append("-- 2. ตาราง stalls (50 แผง: available 47 แผง, maintenance 3 แผง)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT stalls ON;")
    for zid in range(1, 6):
        prefix = zone_prefixes[zid]
        size_sqm = zone_sizes[zid]
        for num in range(1, 11):
            code = f"{prefix}{num:02d}"
            status = 'maintenance' if (zid in [1, 3, 5] and num == 10) else 'available'
            sql.append(
                f"INSERT INTO stalls (stall_id, zone_id, stall_code, size_sqm, status) "
                f"VALUES ({stall_id_counter}, {zid}, N'{code}', {size_sqm:.2f}, '{status}');"
            )
            stalls.append((stall_id_counter, zid, code, size_sqm, status))
            stall_id_counter += 1
    sql.append("SET IDENTITY_INSERT stalls OFF;\nGO\n")

    # ----------------------------------------------------
    # 3. merchants (40 ผู้ค้า)
    # ----------------------------------------------------
    merchant_data = [
        ('สมชาย ขยันค้า', 'อาหารตามสั่งและข้าวแกง'),
        ('สมหญิง ใจดี', 'น้ำผลไม้ปั่นและสมูทตี้'),
        ('อนุชา ริมทาง', 'ลูกชิ้นปิ้งและของทอด'),
        ('วิภาดา พาณิชย์', 'เสื้อผ้าแฟชั่นสตรี'),
        ('เกรียงไกร มีทรัพย์', 'อาหารทะเลสดแช่เย็น'),
        ('นภาลัย ขายดี', 'เบเกอรี่และขนมปังโฮมเมด'),
        ('ปิยะ ค้าส่ง', 'รองเท้าและกระเป๋าแฟชั่น'),
        ('รัตนา การค้า', 'ผักปลอดสารพิษและผลไม้'),
        ('ชาญชัย โปรโมชั่น', 'อุปกรณ์มือถือและเคส'),
        ('สุดา สินค้าดี', 'ก๋วยเตี๋ยวเรือและลวกจิ้ม'),
        ('มานพ ร่ำรวย', 'ชาไข่มุกและกาแฟสด'),
        ('บุญมี โชคดี', 'เนื้อหมูและไก่สดอนามัย'),
        ('วรรณา พาเพลิน', 'เครื่องประดับและกิฟต์ช็อป'),
        ('สมศักดิ์ ขนมไทย', 'ขนมไทยโบราณและทองหยิบ'),
        ('จันทรา ผลไม้สด', 'ผลไม้ตามฤดูกาลปอกพร้อมทาน'),
        ('ประสิทธิ์ กาแฟโบราณ', 'กาแฟโบราณและปาท่องโก๋'),
        ('อภิรดี เสื้อผ้างาม', 'เสื้อยืดและกางเกงยีนส์'),
        ('ธนากร ของเล่น', 'ของเล่นเสริมพัฒนาการ'),
        ('กิตติพงษ์ ยีนส์แท้', 'เสื้อแจ็คเก็ตและกางเกงวินเทจ'),
        ('พิมพา เครื่องประดับ', 'ต่างหูและสร้อยคอแฮนด์เมด'),
        ('สุรชัย ไก่ย่าง', 'ไก่ย่างวิเชียรบุรีและส้มตำ'),
        ('มาลี ข้าวเหนียวมะม่วง', 'ข้าวเหนียวมะม่วงและกะทิสด'),
        ('ธีรพงษ์ ซีฟู้ด', 'กุ้งเผาและปลาหมึกย่าง'),
        ('กัลยา ผ้าไทย', 'ชุดผ้าฝ้ายและผ้าพื้นเมือง'),
        ('ณรงค์ เครื่องครัว', 'เครื่องครัวสแตนเลสและพลาสติก'),
        ('พรทิพย์ ยำแซ่บ', 'ยำรวมมิตรและส้มตำถาด'),
        ('วัชระ เครปญี่ปุ่น', 'เครปญี่ปุ่นและวาฟเฟิล'),
        ('ศิริลักษณ์ ผักสด', 'ผักสลัดไฮโดรโปนิกส์'),
        ('เอกชัย หมวกเท่', 'หมวกแฟชั่นและแว่นกันแดด'),
        ('ดวงใจ ของชำ', 'ของใช้ในครัวเรือนราคาประหยัด'),
        ('นิรันดร์ หมูปิ้ง', 'หมูปิ้งนมสดและข้าวเหนียว'),
        ('อารยา ชาไทย', 'ชาไทยเข้มข้นและโกโก้'),
        ('พงศกร ลูกชิ้นปลา', 'ลูกชิ้นปลาแท้และเกี๊ยวปลา'),
        ('ชไมพร เดรสสวย', 'ชุดเดรสทำงานและลำลอง'),
        ('สมหมาย ต้นไม้', 'ไม้ประดับและแคคตัสจิ๋ว'),
        ('กนกวรรณ ทาโกะยากิ', 'ทาโกะยากิและพิซซ่าญี่ปุ่น'),
        ('ภานุวัฒน์ น้ำส้มคั้น', 'น้ำส้มคั้นสดและน้ำทับทิม'),
        ('ลัดดา ปลาทูแม่กลอง', 'ปลาทูนึ่งและอาหารแห้ง'),
        ('วีระ เสื้อกีฬา', 'ชุดออกกำลังกายและถุงเท้า'),
        ('เพ็ญศรี กระเป๋าสาน', 'กระเป๋าสานและงานจักสาน')
    ]

    sql.append("-- ========================================================================================")
    sql.append("-- 3. ตาราง merchants (40 แถว)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT merchants ON;")
    for mid, (mname, gtype) in enumerate(merchant_data, start=1):
        phone = f"08{mid:02d}{100000 + mid * 1357:06d}"
        sql.append(
            f"INSERT INTO merchants (merchant_id, merchant_name, phone, goods_type) "
            f"VALUES ({mid}, N'{mname}', '{phone}', N'{gtype}');"
        )
    sql.append("SET IDENTITY_INSERT merchants OFF;\nGO\n")

    # ----------------------------------------------------
    # 4. market_days (45 วันตลาด: ก.ค. - ต.ค. 2569 / 2026)
    # ----------------------------------------------------
    # ครอบคลุมเดือนกันยายน 2569 (2026-09-01 ถึง 2026-09-30) สำหรับ Query 04
    # และมีวันก่อนหน้า 2026-10-01 สำหรับ Query 06
    market_days = []  # (market_day_id, date_str, is_open)
    cur_date = datetime(2026, 7, 3)
    mday_id = 1

    sql.append("-- ========================================================================================")
    sql.append("-- 4. ตาราง market_days (51 แถว: อดีต 45 วัน [เปิด 42, ปิดปรับปรุง 3] + อนาคต 6 วันสำหรับสาธิตการจอง)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT market_days ON;")
    while len(market_days) < 45:
        if cur_date.weekday() in [4, 5, 6]:  # ศุกร์, เสาร์, อาทิตย์
            d_str = cur_date.strftime('%Y-%m-%d')
            is_open = 0 if mday_id in [10, 22, 35] else 1
            sql.append(
                f"INSERT INTO market_days (market_day_id, market_date, is_open) "
                f"VALUES ({mday_id}, '{d_str}', {is_open});"
            )
            market_days.append((mday_id, d_str, is_open))
            mday_id += 1
        cur_date += timedelta(days=1)

    # วันตลาดในอนาคต (พ.ย.-ธ.ค. 2569) เปิดรับจองแต่ยังไม่มีสัญญา ไว้สาธิตตอนอัดวิดีโอ
    # ไม่ใส่ลงลิสต์ market_days เพื่อไม่ให้ถูกนำไปสร้าง leases และไม่กระทบลำดับสุ่มของข้อมูลเดิม
    future_market_dates = ['2026-11-06', '2026-11-07', '2026-11-08',
                           '2026-12-04', '2026-12-05', '2026-12-06']
    sql.append("-- วันตลาดในอนาคต (พ.ย.-ธ.ค. 2569) เปิดรับจองแต่ยังไม่มีสัญญา ไว้สาธิต sp_reserve_stall / sp_record_utility / sp_cancel_lease")
    for d_str in future_market_dates:
        sql.append(
            f"INSERT INTO market_days (market_day_id, market_date, is_open) "
            f"VALUES ({mday_id}, '{d_str}', 1);"
        )
        mday_id += 1
    sql.append("SET IDENTITY_INSERT market_days OFF;\nGO\n")

    # ----------------------------------------------------
    # 5. staff (20 พนักงาน)
    # ----------------------------------------------------
    staff_list = [
        ('ประวิทย์ มั่นคง', 'ผู้จัดการตลาด'),
        ('สุภาพร ใจเย็น', 'หัวหน้าฝ่ายการเงิน'),
        ('ดำรงค์ ตรวจการ', 'หัวหน้าฝ่ายจัดระเบียบแผง'),
        ('กิตติ ปฏิบัติงาน', 'เจ้าหน้าที่การเงินและรับชำระ'),
        ('สิริพร ต้อนรับ', 'เจ้าหน้าที่ดูแลสัญญาเช่า'),
        ('วีระพล ช่างซ่อม', 'เจ้าหน้าที่ซ่อมบำรุงและไฟฟ้า'),
        ('ธิดา ยิ้มแย้ม', 'เจ้าหน้าที่ดูแลสัญญาเช่า'),
        ('ชลทิศ บริการ', 'เจ้าหน้าที่การเงินและรับชำระ'),
        ('นริศ ดูแลระบบ', 'เจ้าหน้าที่จดมิเตอร์น้ำ-ไฟ'),
        ('อัมพร บันทึกข้อมูล', 'เจ้าหน้าที่ธุรการตลาด'),
        ('เสกสรร ขยันงาน', 'เจ้าหน้าที่ตรวจสอบความสะอาด'),
        ('ปวีณา สุขใจ', 'เจ้าหน้าที่การเงินและรับชำระ'),
        ('อนุรักษ์ รักษาการณ์', 'เจ้าหน้าที่จัดระเบียบแผง'),
        ('ขวัญใจ ไมตรี', 'เจ้าหน้าที่ประชาสัมพันธ์'),
        ('ภูมิพัฒน์ ช่างเทคนิค', 'เจ้าหน้าที่จดมิเตอร์น้ำ-ไฟ'),
        ('นันทนา การบัญชี', 'เจ้าหน้าที่ตรวจสอบบัญชี'),
        ('ไพโรจน์ ดูแลพื้นที่', 'เจ้าหน้าที่จัดระเบียบแผง'),
        ('สุพัตรา งานละเอียด', 'เจ้าหน้าที่ดูแลสัญญาเช่า'),
        ('วรพจน์ ตรวจมิเตอร์', 'เจ้าหน้าที่จดมิเตอร์น้ำ-ไฟ'),
        ('จิราภรณ์ ประสานงาน', 'เจ้าหน้าที่ธุรการตลาด')
    ]
    sql.append("-- ========================================================================================")
    sql.append("-- 5. ตาราง staff (20 แถว)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT staff ON;")
    for sid, (sname, pos) in enumerate(staff_list, start=1):
        sql.append(
            f"INSERT INTO staff (staff_id, staff_name, position) "
            f"VALUES ({sid}, N'{sname}', N'{pos}');"
        )
    sql.append("SET IDENTITY_INSERT staff OFF;\nGO\n")

    # ----------------------------------------------------
    # 6. leases (ตารางหลัก: 540+ แถว)
    # ----------------------------------------------------
    available_stalls = [s for s in stalls if s[4] == 'available']  # 47 แผง
    zone_info = {z[0]: (z[2], z[3]) for z in zones}

    # กันแผง 5 แผง (stall_id: 9, 19, 29, 39, 49) ไม่ให้ถูกเช่าในรอบวันตลาดที่เปิดทั้งหมดตั้งแต่ 2026-09-15
    # และให้แผงที่เหลือ (42 แผง) ถูกเช่า "หมุนเวียนต่อเนื่อง" (round-robin) ในช่วงนี้
    # เพื่อให้ทุกหน้าต่าง 5 วันตลาดที่เปิดล่าสุดมีครบทุกแผงที่เหลือ
    # Query 06 จึงได้ผลลัพธ์ 5 แผง (9, 19, 29, 39, 49) เมื่อรันตั้งแต่วันที่ 28 ก.ย. 2569 เป็นต้นไป
    # (เดิมใช้การสุ่ม ทำให้มีแผงอื่นบังเอิญว่างเพิ่มอีก 10 แผง ได้ 15 แถว)
    unrented_recent_stall_ids = {9, 19, 29, 39, 49}
    ring_rng = random.Random(2569)  # ตัวสุ่มแยก ไม่กระทบลำดับสุ่มหลักของข้อมูลช่วงก่อน 15 ก.ย.
    rotation_ring = [s for s in available_stalls if s[0] not in unrented_recent_stall_ids]
    ring_rng.shuffle(rotation_ring)
    ring_pos = 0

    # กำหนด 6 วันตลาดพิเศษที่มีผู้เช่าหนาแน่น (Peak Days) เพื่อให้ Query 05 ได้ผลลัพธ์ 6 แถว (ในช่วง 3-10 แถว)
    peak_day_ids = {6, 14, 20, 27, 33, 40}

    sql.append("-- ========================================================================================")
    sql.append("-- 6. ตาราง leases (ตารางหลัก 540+ แถว)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT leases ON;")

    lease_records = []  # (lease_id, stall_id, zone_id, merchant_id, market_day_id, staff_id, rent_price, deposit_amount, status, date_str, is_peak)
    lease_id = 1

    open_days = [d for d in market_days if d[2] == 1]  # 42 วันตลาดที่เปิด
    for day_id, d_str, _ in open_days:
        is_recent_period = (d_str >= '2026-09-15')
        is_peak = (day_id in peak_day_ids)

        candidate_stalls = [
            s for s in available_stalls
            if not (is_recent_period and s[0] in unrented_recent_stall_ids)
        ]

        if is_peak:
            num_stalls = 24  # วันตลาดคึกคักพิเศษ (24 แผง)
        else:
            num_stalls = random.randint(11, 13)  # วันปกติ (11-13 แผง)

        if is_recent_period:
            # ช่วงหลัง 15 ก.ย.: เลือกแผงต่อเนื่องจากวงหมุน (ไม่ซ้ำกันในวันเดียวกัน เพราะ n <= ขนาดวง)
            n = min(num_stalls, len(rotation_ring))
            selected_stalls = [rotation_ring[(ring_pos + k) % len(rotation_ring)] for k in range(n)]
            ring_pos = (ring_pos + n) % len(rotation_ring)
        else:
            selected_stalls = random.sample(candidate_stalls, min(num_stalls, len(candidate_stalls)))
        selected_stalls.sort(key=lambda x: x[0])

        # สุ่มผู้ค้าไม่ให้ซ้ำกันในวันเดียวกัน
        day_merchants = random.sample(range(1, 41), len(selected_stalls))

        for idx, st in enumerate(selected_stalls):
            s_id, z_id, code, _, _ = st
            m_id = day_merchants[idx]
            stf_id = random.choice([4, 5, 7, 8, 12, 18])
            base_rent, dep_pct = zone_info[z_id]
            dep_amt = round(base_rent * (dep_pct / 100.0), 2)

            # ให้มีสัญญาที่ถูกยกเลิก (cancelled) ประมาณ 4% (ยกเว้นวัน Peak เพื่อให้รายได้วัน Peak ชัดเจน)
            # ช่วงตั้งแต่ 15 ก.ย. ไม่ให้ยกเลิก เพื่อไม่ให้แผงหลุดจากการหมุนเวียนและทำให้ Query 06 ได้แผงว่างเกินที่ตั้งใจ
            is_cancelled = (not is_peak) and (not is_recent_period) and (lease_id % 25 == 0)
            status = 'cancelled' if is_cancelled else 'rented'

            created_at = f"{d_str} 07:{random.randint(10, 55):02d}:00"
            cancelled_at = f"'{d_str} 08:{random.randint(30, 59):02d}:00'" if is_cancelled else "NULL"

            sql.append(
                f"INSERT INTO leases (lease_id, stall_id, merchant_id, market_day_id, staff_id, rent_price, deposit_amount, status, created_at, cancelled_at) "
                f"VALUES ({lease_id}, {s_id}, {m_id}, {day_id}, {stf_id}, {base_rent:.2f}, {dep_amt:.2f}, '{status}', '{created_at}', {cancelled_at});"
            )
            lease_records.append((lease_id, s_id, z_id, m_id, day_id, stf_id, base_rent, dep_amt, status, d_str, is_peak))
            lease_id += 1

    sql.append("SET IDENTITY_INSERT leases OFF;\nGO\n")

    # ----------------------------------------------------
    # 7. utility_charges (ค่าน้ำ + ค่าไฟ ของทุกสัญญาที่ status = 'rented')
    # ----------------------------------------------------
    # หมายเหตุ: ไม่ INSERT คอลัมน์ charge_amount เพราะระบบคำนวณอัตโนมัติ (units_used * unit_rate)
    # กำหนดให้โซน 1, 2, 3 (อาหาร/เครื่องดื่ม/ของสด) มีการใช้ไฟเฉลี่ย > 100 หน่วยในเดือน ก.ย. 2569
    # เพื่อให้ Query 04 ได้ผลลัพธ์ 3 โซนแม้ใช้เกณฑ์ > 100 หน่วยตามโจทย์
    sql.append("-- ========================================================================================")
    sql.append("-- 7. ตาราง utility_charges (1,000+ แถว: แยก water และ electricity, ไม่ใส่ charge_amount)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT utility_charges ON;")
    charge_id = 1
    lease_utility_totals = {}  # lease_id -> total_utility_cost

    for l in lease_records:
        l_id, s_id, z_id, m_id, day_id, stf_id, rent_price, dep_amt, status, d_str, is_peak = l
        if status == 'rented':
            rec_at = f"{d_str} 20:30:00"
            # 1) รายการค่าน้ำ (water)
            if z_id in [1, 2, 3]:
                w_units = round(random.uniform(6.0, 14.0), 2)
            else:
                w_units = round(random.uniform(1.0, 4.0), 2)
            w_rate = 18.00
            w_cost = round(w_units * w_rate, 2)

            sql.append(
                f"INSERT INTO utility_charges (charge_id, lease_id, utility_type, units_used, unit_rate, recorded_at) "
                f"VALUES ({charge_id}, {l_id}, 'water', {w_units:.2f}, {w_rate:.2f}, '{rec_at}');"
            )
            charge_id += 1

            # 2) รายการค่าไฟ (electricity)
            if z_id == 1:
                e_units = round(random.uniform(115.0, 145.0), 2)  # เฉลี่ย ~130 หน่วย (> 100)
            elif z_id == 2:
                e_units = round(random.uniform(105.0, 130.0), 2)  # เฉลี่ย ~117 หน่วย (> 100)
            elif z_id == 3:
                e_units = round(random.uniform(110.0, 135.0), 2)  # เฉลี่ย ~122 หน่วย (> 100)
            elif z_id == 4:
                e_units = round(random.uniform(25.0, 45.0), 2)    # เฉลี่ย ~35 หน่วย
            else:
                e_units = round(random.uniform(15.0, 30.0), 2)    # เฉลี่ย ~22 หน่วย

            e_rate = 8.00
            e_cost = round(e_units * e_rate, 2)

            sql.append(
                f"INSERT INTO utility_charges (charge_id, lease_id, utility_type, units_used, unit_rate, recorded_at) "
                f"VALUES ({charge_id}, {l_id}, 'electricity', {e_units:.2f}, {e_rate:.2f}, '{rec_at}');"
            )
            charge_id += 1

            lease_utility_totals[l_id] = round(w_cost + e_cost, 2)

    sql.append("SET IDENTITY_INSERT utility_charges OFF;\nGO\n")

    # ----------------------------------------------------
    # 8. fine_logs (30 รายการค่าปรับ)
    # ----------------------------------------------------
    # กำหนดให้ผู้ค้า 5 ราย (merchant_id: 1, 3, 6, 10, 15) โดนปรับคนละ 3-4 ครั้ง (> 2 ครั้ง)
    # เพื่อให้ Query 03 ได้ผลลัพธ์ 5 แถวอย่างชัดเจน
    fine_reasons = [
        'เก็บแผงค้าและอุปกรณ์เกินเวลาที่ตลาดกำหนด',
        'ทิ้งขยะและน้ำเสียไม่ถูกจุดที่ตลาดจัดเตรียมไว้',
        'วางสินค้าล้ำแนวเขตทางเดินส่วนกลาง',
        'เปิดเครื่องเสียงดังรบกวนร้านค้าข้างเคียง',
        'จอดรถขนถ่ายสินค้าในพื้นที่ห้ามจอดเกินเวลา'
    ]
    sql.append("-- ========================================================================================")
    sql.append("-- 8. ตาราง fine_logs (30 แถว)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT fine_logs ON;")

    fine_records = []  # (fine_id, lease_id, staff_id, amount, f_date)
    fine_id = 1
    target_repeat_merchants = {1: 4, 3: 4, 6: 3, 10: 3, 15: 3}  # รวม 17 รายการจาก 5 คนนี้
    merchant_fine_counts = {m: 0 for m in target_repeat_merchants}

    rented_leases = [l for l in lease_records if l[8] == 'rented']

    # เติมค่าปรับให้ผู้ค้าเป้าหมาย 5 คนก่อน
    for l in rented_leases:
        l_id, s_id, z_id, m_id, day_id, stf_id, rent_price, dep_amt, status, d_str, _ = l
        if m_id in target_repeat_merchants and merchant_fine_counts[m_id] < target_repeat_merchants[m_id]:
            f_staff = random.choice([3, 11, 13, 17])
            reason = fine_reasons[(fine_id - 1) % len(fine_reasons)]
            f_amount = random.choice([200.00, 300.00, 500.00])
            f_date = f"{d_str} 19:15:00"
            sql.append(
                f"INSERT INTO fine_logs (fine_id, lease_id, staff_id, reason, amount, fined_at) "
                f"VALUES ({fine_id}, {l_id}, {f_staff}, N'{reason}', {f_amount:.2f}, '{f_date}');"
            )
            fine_records.append((fine_id, l_id, f_staff, f_amount, f_date))
            merchant_fine_counts[m_id] += 1
            fine_id += 1

    # เติมค่าปรับให้ผู้ค้าคนอื่น ๆ อีกคนละ 1-2 ครั้งจนครบ 30 รายการ
    other_merchants_fined = {}
    for l in rented_leases:
        if fine_id > 30:
            break
        l_id, s_id, z_id, m_id, day_id, stf_id, rent_price, dep_amt, status, d_str, _ = l
        if m_id not in target_repeat_merchants and other_merchants_fined.get(m_id, 0) < 2 and (l_id % 19 == 0):
            f_staff = random.choice([3, 11, 13, 17])
            reason = fine_reasons[(fine_id - 1) % len(fine_reasons)]
            f_amount = random.choice([200.00, 300.00])
            f_date = f"{d_str} 19:30:00"
            sql.append(
                f"INSERT INTO fine_logs (fine_id, lease_id, staff_id, reason, amount, fined_at) "
                f"VALUES ({fine_id}, {l_id}, {f_staff}, N'{reason}', {f_amount:.2f}, '{f_date}');"
            )
            fine_records.append((fine_id, l_id, f_staff, f_amount, f_date))
            other_merchants_fined[m_id] = other_merchants_fined.get(m_id, 0) + 1
            fine_id += 1

    sql.append("SET IDENTITY_INSERT fine_logs OFF;\nGO\n")

    # ----------------------------------------------------
    # 9. payments (ไม่มีคอลัมน์ fine_id ตาม Schema v0.1)
    # ----------------------------------------------------
    # ประเภทการจ่าย: 'rent', 'deposit', 'utility', 'fine', 'deposit_refund'
    sql.append("-- ========================================================================================")
    sql.append("-- 9. ตาราง payments (1,600+ แถว: ไม่มี fine_id, ยกเลิกสัญญาคืนเฉพาะ deposit_refund)")
    sql.append("-- ========================================================================================")
    sql.append("SET IDENTITY_INSERT payments ON;")
    payment_id = 1

    for l in lease_records:
        l_id, s_id, z_id, m_id, day_id, stf_id, rent_price, dep_amt, status, d_str, _ = l
        pay_time = f"{d_str} 07:58:00"

        # 1) จ่ายค่าเช่า (rent) และ 2) จ่ายเงินมัดจำ (deposit) ตอนทำสัญญา
        sql.append(
            f"INSERT INTO payments (payment_id, lease_id, staff_id, payment_type, amount, paid_at) "
            f"VALUES ({payment_id}, {l_id}, {stf_id}, 'rent', {rent_price:.2f}, '{pay_time}');"
        )
        payment_id += 1

        sql.append(
            f"INSERT INTO payments (payment_id, lease_id, staff_id, payment_type, amount, paid_at) "
            f"VALUES ({payment_id}, {l_id}, {stf_id}, 'deposit', {dep_amt:.2f}, '{pay_time}');"
        )
        payment_id += 1

        if status == 'rented':
            # 3) จ่ายค่าน้ำไฟ (utility) ตอนปิดตลาด
            util_amt = lease_utility_totals.get(l_id, 0.00)
            if util_amt > 0:
                util_pay_time = f"{d_str} 20:45:00"
                sql.append(
                    f"INSERT INTO payments (payment_id, lease_id, staff_id, payment_type, amount, paid_at) "
                    f"VALUES ({payment_id}, {l_id}, {stf_id}, 'utility', {util_amt:.2f}, '{util_pay_time}');"
                )
                payment_id += 1
        elif status == 'cancelled':
            # สัญญาที่ยกเลิก: คืนเฉพาะเงินมัดจำ (deposit_refund) ไม่คืนค่าเช่า
            refund_time = f"{d_str} 09:05:00"
            sql.append(
                f"INSERT INTO payments (payment_id, lease_id, staff_id, payment_type, amount, paid_at) "
                f"VALUES ({payment_id}, {l_id}, {stf_id}, 'deposit_refund', {dep_amt:.2f}, '{refund_time}');"
            )
            payment_id += 1

    # 4) จ่ายค่าปรับ (payment_type = 'fine' คู่กับ lease_id โดยไม่มี fine_id)
    for f_id, l_id, f_staff, f_amount, f_date in fine_records:
        sql.append(
            f"INSERT INTO payments (payment_id, lease_id, staff_id, payment_type, amount, paid_at) "
            f"VALUES ({payment_id}, {l_id}, {f_staff}, 'fine', {f_amount:.2f}, '{f_date}');"
        )
        payment_id += 1

    sql.append("SET IDENTITY_INSERT payments OFF;\nGO\n")
    sql.append(f"-- สรุปผลการสร้างข้อมูล: leases = {len(lease_records)} แถว, utility_charges = {charge_id - 1} แถว, fine_logs = {fine_id - 1} แถว, payments = {payment_id - 1} แถว")

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(sql))

    print(f"สร้างไฟล์ {output_path} สำเร็จ!")
    print(f"- stall_zones: {len(zones)} แถว")
    print(f"- stalls: {len(stalls)} แถว")
    print(f"- merchants: {len(merchant_data)} แถว")
    print(f"- market_days: {len(market_days) + len(future_market_dates)} แถว")
    print(f"- staff: {len(staff_list)} แถว")
    print(f"- leases: {len(lease_records)} แถว")
    print(f"- utility_charges: {charge_id - 1} แถว")
    print(f"- fine_logs: {fine_id - 1} แถว")
    print(f"- payments: {payment_id - 1} แถว")

if __name__ == "__main__":
    generate_market_data("data.sql")