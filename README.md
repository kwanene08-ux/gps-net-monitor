# GPS Net Monitor (Flutter)

แอปต้นแบบสำหรับไรเดอร์ แสดงตำแหน่งจาก provider GPS, ตรวจความแม่นยำ/ความเร็ว และสถานะชนิดเครือข่าย พร้อม foreground service และปุ่มหยุดใน notification

> **สถานะความพร้อม:** นี่คือ starter project ยังไม่ใช่ APK ที่ผ่านการทดสอบบน Vivo จริง และยังต้องให้ GitHub Actions build/analyze ผ่านก่อนใช้งานวิ่งงานจริง อย่าใช้เป็นระบบนำทางหลักจนทดสอบครบ

## สิ่งที่ทำได้ในรุ่น starter
- เริ่มติดตามด้วยการกดปุ่มเอง ไม่เริ่มอัตโนมัติ
- Foreground service มี notification คงอยู่และปุ่ม “หยุด”
- อ่านตำแหน่งผ่าน Geolocator และปฏิเสธ accuracy เกิน 100 เมตร/ความเร็วกระโดดเกิน 60 m/s
- แสดงชนิดการเชื่อมต่อที่ `connectivity_plus` รายงาน
- เช็ค GitHub Release ล่าสุดและดาวน์โหลด APK เพื่อนำไปเปิดหน้าติดตั้ง

## ข้อจำกัดที่ต้องทราบ
- `forceLocationManager: true` ในตัวอย่างที่ให้มาไม่ใส่ไว้ เพราะ API `geolocator 12` ไม่รองรับพารามิเตอร์นี้ใน `AndroidSettings` ทุกเวอร์ชัน; โค้ดใช้ `LocationSettings` และ Android จะเลือก provider ตามปลั๊กอิน/อุปกรณ์ ต้องตรวจยืนยันว่า `provider: gps` เป็นค่าจากตำแหน่งจริงก่อนเชื่อถือ
- จำนวนดาวเทียมและ dBm ไม่ได้มี API ข้ามเครื่องที่เชื่อถือได้ในชุด dependency นี้ จึงแสดง N/A; ไม่ได้เดาค่า
- คะแนนรวมจะต่ำหาก dBm เป็น N/A เพราะยังไม่รวมการอ่าน cellular signal แบบ OEM-specific
- ตัวกรองนี้เป็น outlier gate อย่างง่าย **ยังไม่ใช่ Kalman filter** และยังไม่มี alert notification สำหรับทุกเหตุการณ์
- การทำงานปิดจอขึ้นกับสิทธิ์ Location “Allow all the time”, notification และข้อจำกัดแบตเตอรี่ของ Vivo
- Auto-update ต้องติดตั้ง APK ที่เซ็นด้วย certificate เดียวกันกับรุ่นก่อนหน้า; หากใช้ signing key ต่างกัน Android จะปฏิเสธการอัปเดต

## วิธีสร้าง repository และ build APK ผ่านมือถือ
1. เข้า https://github.com แล้วสมัคร/เข้าสู่ระบบ
2. สร้าง repository ใหม่ชื่อ `gps-net-monitor` และเลือก Public หรือ Private ตามต้องการ
3. อัปโหลดไฟล์/โฟลเดอร์ทั้งหมดจาก ZIP นี้ โดยคงโครงสร้างเดิม (รวม `.github/workflows/build.yml`). หากอัปโหลดผ่านเว็บ ให้ใช้ **Add file → Upload files** และลากไฟล์ทั้งหมดจากโฟลเดอร์ที่แตก ZIP แล้ว
4. ใน `lib/main.dart` แก้ `YOUR_GITHUB_USERNAME/gps-net-monitor` ให้ตรงกับชื่อบัญชีและ repository
5. แก้ไข `pubspec.yaml` แล้วเพิ่มเลข build ทุกครั้ง เช่น `1.0.1+2`, `1.0.2+3` ก่อนเผยแพร่รุ่นใหม่
6. เปิดแท็บ **Actions** ใน repo แล้วอนุญาต Actions หาก GitHub ขอ จากนั้นรอ workflow จบ
7. ดาวน์โหลด APK จาก run ล่าสุดใน Actions → Artifacts → `gps-net-monitor-apk` (หรือ Release ที่สร้างจากการกด Run workflow หากเป็น version ใหม่)

## ติดตั้ง APK
1. แตก ZIP artifact แล้วแตะ `app-release.apk`
2. หาก Android ถาม ให้เปิด “อนุญาตจากแหล่งที่มานี้” สำหรับ browser/Files ที่ใช้เปิด APK
3. ถ้าติดตั้งทับรุ่นเดิมไม่ผ่าน ให้ตรวจว่ารุ่นเดิมมาจาก signing key เดียวกัน ห้ามถอนแอปก่อนสำรองข้อมูลที่จำเป็น

## ตั้งค่า Vivo Android 15 ให้ทำงานเบื้องหลัง
ชื่อเมนูอาจต่างกันตาม Funtouch OS/ภูมิภาค:
1. Settings → Apps → GPS Net Monitor → Permissions → Location → อนุญาตตำแหน่ง และเลือก **Allow all the time** หากมี
2. เปิด Notifications สำหรับแอป
3. Settings → Battery / Background power consumption management → ตั้งแอปเป็น **ไม่จำกัด/Allow background activity** หากมี
4. เปิด Auto-start สำหรับแอป หากเมนูนี้มีในเครื่อง
5. ปักหมุด/ล็อกแอปในหน้า Recent apps หากเครื่องมีตัวเลือกนี้
6. เปิด Location และเลือกโหมดที่เน้นอุปกรณ์/GPS หากมีตัวเลือกดังกล่าว ทั้งนี้ Android รุ่นใหม่บางเครื่องไม่มีสวิตช์ “Device only” แบบเดิม
7. ทดสอบโดยเริ่มติดตาม ล็อกหน้าจอ 10–15 นาที แล้วกลับมาตรวจว่าค่าตำแหน่งยังอัปเดตหรือไม่

## ใช้งาน
- เปิดแอปแล้วกด **เริ่มติดตาม** เพื่อเริ่ม service
- ออกจากแอปหรือปิดจอได้; notification ควรคงอยู่ แต่ Vivo อาจหยุด process ได้หากจำกัดแบตเตอรี่
- กด **หยุดติดตาม** ในแอปหรือปุ่ม **หยุด** บน notification
- ปุ่มตั้งค่าจะเปิดหน้าตั้งค่า Location/แอปเพื่อให้ผู้ใช้ปรับสิทธิ์เอง
- กด **เช็คอัปเดต** เพื่อตรวจ GitHub Release ล่าสุด

## อัปเดต
- เปลี่ยน `version:` ใน `pubspec.yaml` ทุกครั้ง เช่น `1.0.1+2`
- Build ผ่าน Actions และสร้าง Release รุ่นใหม่
- ติดตั้งรุ่นใหม่ด้วย signing certificate เดิมเท่านั้น

## ความเป็นส่วนตัว
แอปนี้ไม่ส่งตำแหน่งไปยังเซิร์ฟเวอร์ของผู้พัฒนาโดยเจตนา การเช็คอัปเดตจะติดต่อ GitHub API และดาวน์โหลด APK จาก Release ที่ตั้งค่าไว้
