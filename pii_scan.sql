/*==============================================================================
  pii-scan-ge  —  PII სკანერი MS SQL Server-ისთვის (ქართული კონტექსტი)

  დანიშნულება:
    ბაზაში პერსონალური მონაცემების აღმოჩენა ორ ეტაპად —
      1) სვეტის სახელის ევრისტიკა (მეტამონაცემები, მონაცემს არ კითხულობს)
      2) მონაცემის შერჩევითი სკანირება (TOP N, პატერნების შემოწმება)

  მოთხოვნები:  SQL Server 2012+ ,  VIEW DEFINITION + SELECT უფლება
  გაშვება:     გახსენი სამიზნე ბაზაზე SSMS-ში და გაუშვი. არაფერს წერს ბაზაში.

  ⚠️  ყოველთვის გაუშვი READ-ONLY replica-ზე ან არასამუშაო საათებში.
      WITH (NOLOCK) გამოიყენება — dirty read დასაშვებია, რადგან შედეგი
      სტატისტიკურია და არა ტრანზაქციული.
==============================================================================*/

--------------------------------------------------------------------------------
-- 0. სამიზნე ბაზა
--
--    სკრიპტს ბაზის პარამეტრი არ აქვს — ის მიმდინარე კავშირის ბაზაზე მუშაობს,
--    რადგან sys.columns / sys.tables თითოეულ ბაზაში ცალკე არსებობს.
--
--    ან აირჩიე ბაზა SSMS-ის ტულბარზე („Available Databases"),
--    ან გახსენი ქვემოთა ორი ხაზი და ჩაწერე სახელი.
--
--    GO აუცილებელია: მთელი დანარჩენი ფაილი ერთი ბატჩია და USE ცალკე
--    ბატჩში უნდა დარჩეს, რომ DECLARE-ები უკვე ახალ კონტექსტში შესრულდეს.
--
--    ერთ გაშვებაზე — ერთი ბაზა.
--------------------------------------------------------------------------------
-- USE [შენი_ბაზის_სახელი];
-- GO

SET NOCOUNT ON;

--------------------------------------------------------------------------------
-- 1. კონფიგურაცია
--------------------------------------------------------------------------------
DECLARE @ScriptVersion   NVARCHAR(20)  = N'1.0.0';  -- აისახება ანგარიშ #0-ში
DECLARE @SampleSize      INT           = 500;   -- რამდენი მწკრივი თითო სვეტზე
DECLARE @MinHitPct       DECIMAL(5,2)  = 5.00;  -- ზღვარი: მაჩვენებელი ამაზე ქვემოთ იგნორდება
DECLARE @MinSampleForPct INT           = 10;    -- პროცენტული წესი მხოლოდ ამ ზომის ნიმუშიდან
                                                -- მოქმედებს. ერთმწკრივიან ცხრილში „100%" 
                                                -- არაფერს ნიშნავს — ვერსიის ნომერი IP-დ ითვლებოდა.
DECLARE @MinAbsHits      INT           = 3;     -- აბსოლუტური ზღვარი: ამდენი დამთხვევა ყოველთვის
                                                -- აისახება, პროცენტის მიუხედავად. კომპლაიენსში
                                                -- მნიშვნელოვანია არსებობა, არა გავრცელება —
                                                -- ერთი IBAN არასწორ სვეტში უკვე ინციდენტია.
DECLARE @ScanData        BIT           = 1;     -- 0 = მხოლოდ სახელების ანალიზი (ძალიან სწრაფი)
DECLARE @ScanAllStringCols BIT         = 1;     -- 1 = ყველა ტექსტური სვეტი, არა მხოლოდ სახელით ნაპოვნი
DECLARE @MaxColumnsToScan INT          = 3000;  -- დაცვა უზარმაზარ ბაზებზე
DECLARE @FastMode        BIT           = 1;     -- 1 = ერთი მოთხოვნა ცხრილზე (ბევრად სწრაფი)
                                                -- 0 = ერთი მოთხოვნა სვეტზე; ნელია, სამაგიეროდ
                                                --     ერთი წაუკითხავი სვეტი მთელ ცხრილს არ აგდებს
DECLARE @MinNameConfidence TINYINT     = 50;    -- ზღვარი სახელების ეტაპზე: ამაზე სუსტი დამთხვევა
                                                -- არ იჩენს თავს. 0 = ყველაფერი გამოჩნდეს.
                                                -- მონაცემით ნაპოვნს არ ეხება.

--------------------------------------------------------------------------------
-- 2. სამუშაო ცხრილები
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#col')     IS NOT NULL DROP TABLE #col;
IF OBJECT_ID('tempdb..#find')    IS NOT NULL DROP TABLE #find;
IF OBJECT_ID('tempdb..#agg')     IS NOT NULL DROP TABLE #agg;
IF OBJECT_ID('tempdb..#skipped') IS NOT NULL DROP TABLE #skipped;
IF OBJECT_ID('tempdb..#tbl')     IS NOT NULL DROP TABLE #tbl;
IF OBJECT_ID('tempdb..#hits')    IS NOT NULL DROP TABLE #hits;

CREATE TABLE #col (
    col_id          INT IDENTITY(1,1) PRIMARY KEY,
    schema_name     SYSNAME,
    table_name      SYSNAME,
    column_name     SYSNAME,
    data_type       SYSNAME,
    max_length      INT,
    approx_rows     BIGINT,
    is_text         BIT,
    is_numeric_id   BIT,
    is_likely_fk    BIT,          -- ციფრული სვეტი, სახელი ბოლოვდება „id"-ით
    is_computed     BIT,          -- გამოთვლადი: სახელით მოწმდება, მონაცემით არა
    is_eligible     BIT           NOT NULL DEFAULT 0,   -- სასკანერო კრიტერიუმი, ერთხელ გამოთვლილი
    to_scan         BIT           NOT NULL DEFAULT 0,
    name_category   NVARCHAR(40)  NULL,
    name_confidence TINYINT       NOT NULL DEFAULT 0,
    name_is_special BIT           NOT NULL DEFAULT 0,
    name_needs_review BIT         NOT NULL DEFAULT 0
);

CREATE TABLE #find (
    schema_name     SYSNAME,
    table_name      SYSNAME,
    column_name     SYSNAME,
    data_type       SYSNAME,
    approx_rows     BIGINT,
    category        NVARCHAR(40),
    detected_by     NVARCHAR(20),      -- NAME | DATA | NAME+DATA
    sampled_rows    INT,
    hit_pct         DECIMAL(5,2),
    confidence      TINYINT,           -- 0-100
    is_special      BIT                -- სპეციალური კატეგორიის მონაცემი
);

-- დედუპლიცირებული აღმოჩენები. სამივე ანგარიში ამ ერთ ცხრილზე დგება, რომ
-- ერთმანეთს არ დაუპირისპირდნენ: #find-ში ერთი სვეტი ორჯერ წერია, თუ
-- სახელითაც და მონაცემითაც მოიძებნა.
CREATE TABLE #agg (
    schema_name     SYSNAME,
    table_name      SYSNAME,
    column_name     SYSNAME,
    data_type       SYSNAME,
    approx_rows     BIGINT,
    category        NVARCHAR(40),
    by_name         INT,
    by_data         INT,
    hit_pct         DECIMAL(5,2),
    conf            TINYINT,
    is_special      INT
);

-- სასკანერო ცხრილები. order_col = კლასტერული ინდექსის პირველი სვეტი,
-- ნიმუშის მეორე ნახევრის უკუმიმართულებით ასაღებად. heap-ზე NULL.
CREATE TABLE #tbl (
    tbl_id          INT IDENTITY(1,1) PRIMARY KEY,
    schema_name     SYSNAME,
    table_name      SYSNAME,
    order_col       SYSNAME NULL
);

-- დათვლილი დამთხვევები თითო სვეტზე. n = რამდენი არაცარიელი მნიშვნელობა
-- აღმოჩნდა ნიმუშში — ეს თავისთავად სასარგებლო მაჩვენებელია.
CREATE TABLE #hits (
    schema_name     SYSNAME,
    table_name      SYSNAME,
    column_name     SYSNAME,
    n               INT,
    h_pid           INT,
    h_phone         INT,
    h_land          INT,
    h_mail          INT,
    h_iban          INT,
    h_card          INT,
    h_plate         INT,
    h_ip            INT,
    h_emb_mail      INT,
    h_emb_phone     INT
);

-- გამოტოვებული სვეტები: აუდიტს მოცვის მტკიცებულება სჭირდება, არა მხოლოდ
-- აღმოჩენები. ცარიელი შედეგი „PII არ არის" და „ვერ წავიკითხე" ერთნაირად გამოიყურება.
CREATE TABLE #skipped (
    schema_name     SYSNAME,
    table_name      SYSNAME,
    column_name     SYSNAME,
    reason          NVARCHAR(20),      -- ERROR | COMPUTED
    err             NVARCHAR(400)
);

--------------------------------------------------------------------------------
-- 3. სვეტების ინვენტარიზაცია
--------------------------------------------------------------------------------
INSERT INTO #col (schema_name, table_name, column_name, data_type, max_length,
                  approx_rows, is_text, is_numeric_id, is_likely_fk, is_computed)
SELECT
    s.name,
    t.name,
    c.name,
    ty.name,
    c.max_length,
    ISNULL(ps.row_cnt, 0),
    CASE WHEN ty.name IN ('char','nchar','varchar','nvarchar','text','ntext','sysname')
         THEN 1 ELSE 0 END,
    CASE WHEN ty.name IN ('bigint','numeric','decimal','int')
         THEN 1 ELSE 0 END,
    -- სავარაუდოდ უცხო/სუროგატული გასაღები: ციფრული ტიპი + სახელი „id"-ით მთავრდება.
    -- ასეთი სვეტი პატერნს ხშირად ემთხვევა (PersonID, EmailAddressID, PhotoID),
    -- მაგრამ პერსონალურ მონაცემს არ ინახავს — ანგარიშში ცალკე აღინიშნება.
    CASE WHEN ty.name IN ('bigint','numeric','decimal','int','smallint','tinyint')
              AND LOWER(c.name) LIKE '%id'
         THEN 1 ELSE 0 END,
    c.is_computed
FROM sys.columns  c
JOIN sys.tables   t  ON t.object_id = c.object_id
JOIN sys.schemas  s  ON s.schema_id = t.schema_id
JOIN sys.types    ty ON ty.user_type_id = c.user_type_id
OUTER APPLY (
    SELECT SUM(p.rows) AS row_cnt
    FROM sys.partitions p
    WHERE p.object_id = t.object_id AND p.index_id IN (0,1)
) ps
WHERE t.is_ms_shipped = 0
  AND s.name NOT IN ('sys','INFORMATION_SCHEMA')
  AND ty.name NOT IN ('image','varbinary','binary','xml','geography','geometry',
                      'hierarchyid','timestamp','uniqueidentifier','bit');

--------------------------------------------------------------------------------
-- 4. ეტაპი 1 — სვეტის სახელის ევრისტიკა
--    LOWER() + პატერნები. ქართული ტრანსლიტი და ინგლისური ერთად.
--------------------------------------------------------------------------------
;WITH pat AS (
    SELECT * FROM (VALUES
      -- category                pattern                        conf  special
       (N'პირადი ნომერი',        N'%personal%num%',              90, 0, 0),
       (N'პირადი ნომერი',        N'%personal%no%',               90, 0, 0),
       -- 40: `PersonID` / `SalesPersonID` ტიპის FK-ებს იჭერს ისევე, როგორც
       -- ნამდვილ `personal_id`-ს. ნამდვილს მონაცემის ეტაპი დაადასტურებს (11 ციფრი).
       (N'პირადი ნომერი',        N'%pers%id%',                   40, 0, 0),
       (N'პირადი ნომერი',        N'%piradi%',                    90, 0, 0),
       (N'პირადი ნომერი',        N'%pid%',                       60, 0, 0),
       (N'პირადი ნომერი',        N'%id_number%',                 85, 0, 0),
       (N'პირადი ნომერი',        N'%identity%',                  70, 0, 0),
       (N'პირადი ნომერი',        N'%sagadasakhado%',             70, 0, 0),
       (N'პირადი ნომერი',        N'%tax%id%',                    70, 0, 0),

       (N'სახელი/გვარი',         N'%first%name%',                90, 0, 0),
       (N'სახელი/გვარი',         N'%last%name%',                 90, 0, 0),
       (N'სახელი/გვარი',         N'%full%name%',                 90, 0, 0),
       (N'სახელი/გვარი',         N'%surname%',                   90, 0, 0),
       (N'სახელი/გვარი',         N'%gvari%',                     90, 0, 0),
       (N'სახელი/გვარი',         N'%saxeli%',                    85, 0, 0),
       (N'სახელი/გვარი',         N'%sakheli%',                   85, 0, 0),
       (N'სახელი/გვარი',         N'%patronymic%',                80, 0, 0),

       (N'ტელეფონი',             N'%phone%',                     90, 0, 0),
       (N'ტელეფონი',             N'%mobile%',                    85, 0, 0),
       (N'ტელეფონი',             N'%tel%',                       60, 0, 0),
       (N'ტელეფონი',             N'%mob_nom%',                   85, 0, 0),

       (N'ელფოსტა',              N'%email%',                     95, 0, 0),
       (N'ელფოსტა',              N'%e_mail%',                    95, 0, 0),

       (N'მისამართი',            N'%address%',                   85, 0, 0),
       (N'მისამართი',            N'%misamart%',                  90, 0, 0),
       (N'მისამართი',            N'%street%',                    70, 0, 0),
       (N'მისამართი',            N'%postal%',                    60, 0, 0),
       (N'მისამართი',            N'%zip%',                       55, 0, 0),

       (N'დაბადების თარიღი',     N'%birth%',                     90, 0, 0),
       (N'დაბადების თარიღი',     N'%dabadeb%',                   90, 0, 0),
       (N'დაბადების თარიღი',     N'%dob%',                       70, 0, 0),

       (N'დოკუმენტი',            N'%passport%',                  90, 0, 0),
       (N'დოკუმენტი',            N'%pasport%',                   90, 0, 0),
       (N'დოკუმენტი',            N'%driver%lic%',                85, 0, 0),
       (N'დოკუმენტი',            N'%mowmoba%',                   65, 0, 0),

       (N'ფინანსური',            N'%iban%',                      95, 0, 0),
       (N'ფინანსური',            N'%account%num%',               75, 0, 0),
       (N'ფინანსური',            N'%card%num%',                  90, 0, 0),
       (N'ფინანსური',            N'%bank%',                      60, 0, 0),
       (N'ფინანსური',            N'%salary%',                    70, 0, 0),
       (N'ფინანსური',            N'%xelfas%',                    75, 0, 0),

       (N'ავტომობილი',           N'%plate%',                     80, 0, 0),
       (N'ავტომობილი',           N'%vin%',                       70, 0, 0),

       -- ონლაინ იდენტიფიკატორი კანონით პერსონალური მონაცემია.
       -- ყურადღება: LIKE-ში `_` ერთი ნებისმიერი სიმბოლოა, ანუ `%ip_addr%`
       -- იჭერს `ip_addr`-საც და `ip-addr`-საც, მაგრამ `ipaddress`-ს — არა.
       -- ამიტომ ორივე ვარიანტი ცალკეა ჩაწერილი.
       (N'ონლაინ იდენტიფიკატორი', N'%ip_addr%',                  85, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%ipaddr%',                   85, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%client_ip%',                85, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%remote_ip%',                85, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%mac_addr%',                 85, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%macaddr%',                  85, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%imei%',                     90, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%device%id%',                75, 0, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%session%id%',               70, 0, 0),

       (N'გეოლოკაცია',           N'%latitude%',                  70, 0, 0),
       (N'გეოლოკაცია',           N'%longitude%',                 70, 0, 0),
       (N'გეოლოკაცია',           N'%gps%',                       70, 0, 0),

       -- ↓↓↓ სპეციალური კატეგორიის მონაცემები ↓↓↓
       (N'ჯანმრთელობა ⚠',        N'%diagnos%',                   90, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%icd%',                       75, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%blood%',                     80, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%disabil%',                   85, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%shshm%',                     85, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%health%',                    75, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%medical%',                   80, 1, 0),
       (N'ჯანმრთელობა ⚠',        N'%janmrtel%',                  90, 1, 0),

       (N'ბიომეტრია ⚠',          N'%fingerprint%',               90, 1, 0),
       (N'ბიომეტრია ⚠',          N'%biometr%',                   90, 1, 0),
       (N'ბიომეტრია ⚠',          N'%face%id%',                   70, 1, 0),
       -- 40: პროდუქტის/დოკუმენტის ფოტოს სვეტებს ისევე იჭერს, როგორც ადამიანისას.
       (N'ბიომეტრია ⚠',          N'%photo%',                     40, 1, 0),

       (N'სენსიტიური ⚠',         N'%religio%',                   85, 1, 0),
       (N'სენსიტიური ⚠',         N'%ethnic%',                    85, 1, 0),
       -- მოქალაქეობა სპეციალური კატეგორია არ არის — ეთნიკური კუთვნილებაა.
       -- `nationality` კონტექსტზეა დამოკიდებული: შეიძლება ორივეს ნიშნავდეს,
       -- ამიტომ ჩვეულებრივია, დაბალი ქულით და ხელით შემოწმების შენიშვნით.
       (N'მოქალაქეობა',          N'%citizenship%',               60, 0, 0),
       (N'მოქალაქეობა',          N'%nationalit%',                55, 0, 1),
       (N'სენსიტიური ⚠',         N'%politic%',                   80, 1, 0),
       (N'სენსიტიური ⚠',         N'%criminal%',                  85, 1, 0),
       (N'სენსიტიური ⚠',         N'%nasamartl%',                 90, 1, 0),
       -- სქესი ჩვეულებრივი პერსონალური მონაცემია. სპეციალურ კატეგორიას
       -- სექსუალური ორიენტაცია განეკუთვნება — ეს ორი აქ გამიჯნულია, თორემ
       -- ყოველი Sex/Gender სვეტი RoPA-ში DPIA-ს მოთხოვნას იღებდა.
       (N'სქესი',                N'%sex%',                       55, 0, 0),
       (N'სქესი',                N'%gender%',                    70, 0, 0),
       (N'სენსიტიური ⚠',         N'%sexual%orient%',             90, 1, 0),
       (N'სენსიტიური ⚠',         N'%orientac%',                  80, 1, 0),
       (N'სენსიტიური ⚠',         N'%trade%union%',               80, 1, 0)
    ) v(category, pattern, conf, is_special, needs_review)
),
best AS (
    SELECT c.col_id, p.category, p.conf, p.is_special, p.needs_review,
           -- tiebreak აუცილებელია: `health_icd_code` ორივეს ემთხვევა — %health% (75)
           -- და %icd% (75). მხოლოდ conf-ით დალაგება არჩევანს არადეტერმინირებულს
           -- ხდის და იდენტური ბაზა გაშვებებს შორის სხვადასხვა შედეგს იძლევა.
           ROW_NUMBER() OVER (PARTITION BY c.col_id
                              ORDER BY p.conf DESC, p.category, p.pattern) AS rn
    FROM #col c
    JOIN pat p ON LOWER(REPLACE(c.column_name, ' ', '_')) LIKE p.pattern
)
UPDATE c
   SET name_category   = b.category,
       name_confidence = b.conf,
       name_is_special = b.is_special,
       name_needs_review = b.needs_review
FROM #col c
JOIN best b ON b.col_id = c.col_id AND b.rn = 1;

--------------------------------------------------------------------------------
-- 5. ეტაპი 2 — მონაცემის შერჩევითი სკანირება
--
--    ერთი გავლა ცხრილზე, არა ერთი გავლა სვეტზე. სვეტები CROSS APPLY (VALUES ...)
--    -ით ვერტიკალურად იშლება, ანუ 40-სვეტიან ცხრილს 40 ცალკე TOP N ნაცვლად
--    ერთი მოთხოვნა ხვდება.
--
--    გვერდითი ეფექტი: `n` ახლა თითო სვეტის რეალურ შევსებას ზომავს ნიმუშში,
--    და `WHERE col IS NOT NULL`-ის მთელი ცხრილის სკანირება ქრება.
--------------------------------------------------------------------------------
DECLARE @scanned INT = 0;

IF @ScanData = 1
BEGIN
    -- სასკანერო კრიტერიუმი ერთხელ იწერება და ერთ ფლაგში ინახება.
    -- ორ ადგილას დუბლირება ნიშნავდა, რომ პირობის შეცვლისას მოცვის რიცხვები
    -- ჩუმად აცდებოდა აღმოჩენებს.
    UPDATE #col
       SET is_eligible = CASE WHEN approx_rows > 0
                               AND (   (is_text = 1 AND @ScanAllStringCols = 1)
                                    OR name_category IS NOT NULL
                                    OR is_numeric_id = 1 )
                              THEN 1 ELSE 0 END;

    -- გამოთვლადი სვეტი მონაცემით არ სკანირდება: თითო მწკრივზე გამოსახულების
    -- იძულებით გამოთვლას ნიშნავს. სახელის ევრისტიკა მასზე მაინც მუშაობს.
    INSERT INTO #skipped (schema_name, table_name, column_name, reason, err)
    SELECT schema_name, table_name, column_name, N'COMPUTED',
           N'გამოთვლადი სვეტი — მონაცემი არ წაკითხულა'
    FROM #col
    WHERE is_eligible = 1 AND is_computed = 1;

    UPDATE #col
       SET to_scan = 1
     WHERE is_eligible = 1 AND is_computed = 0;

    -- @MaxColumnsToScan-ის ზღვარი. დალაგება დეტერმინირებულია, რომ ზღვარზე
    -- ყოველთვის ერთი და იგივე ნაკრები მოხვდეს.
    WITH ranked AS (
        SELECT col_id,
               ROW_NUMBER() OVER (ORDER BY name_confidence DESC, approx_rows DESC,
                                           schema_name, table_name, column_name) AS rn
        FROM #col WHERE to_scan = 1
    )
    UPDATE c SET to_scan = 0
    FROM #col c JOIN ranked r ON r.col_id = c.col_id
    WHERE r.rn > @MaxColumnsToScan;

    ----------------------------------------------------------------------------
    -- სასკანერო ცხრილები + დალაგების სვეტი.
    -- order_col = კლასტერული ინდექსის პირველი სვეტი. ნიმუშის მეორე ნახევარი
    -- მისი მიხედვით უკუმიმართულებით აიღება — ჰეტეროგენულ სვეტზე ეს ცრუ
    -- უარყოფითის მთავარ მიზეზს ხურავს. თუ ცხრილი heap-ია, order_col = NULL
    -- და მეორე ნახევარი არ სრულდება: სორტირება მთელ ცხრილზე ძვირი ჯდება.
    ----------------------------------------------------------------------------
    INSERT INTO #tbl (schema_name, table_name, order_col)
    SELECT c.schema_name, c.table_name, MAX(ic.name)
    FROM #col c
    OUTER APPLY (
        SELECT TOP (1) sc.name
        FROM sys.indexes i
        JOIN sys.index_columns xc ON xc.object_id = i.object_id AND xc.index_id = i.index_id
        JOIN sys.columns sc ON sc.object_id = xc.object_id AND sc.column_id = xc.column_id
        WHERE i.object_id = OBJECT_ID(QUOTENAME(c.schema_name) + '.' + QUOTENAME(c.table_name))
          AND i.index_id = 1 AND xc.key_ordinal = 1
    ) ic
    WHERE c.to_scan = 1
    GROUP BY c.schema_name, c.table_name;

    ----------------------------------------------------------------------------
    -- შემოწმებების სია ერთხელ იწერება და ორივე რეჟიმში იგივეა.
    -- r.v  — საწყისი მნიშვნელობა (COLLATE Latin1_General_BIN2)
    -- z.nv — ნორმალიზებული: მოშორებულია ' ', '-', '(', ')', '.'
    -- z.is_dec — სუფთა ათწილადი, ციფრულ ფორმატებში არ ითვლება
    ----------------------------------------------------------------------------
    DECLARE @checks NVARCHAR(MAX) = N'
      SUM(CASE WHEN z.is_dec = 0 AND LEN(z.nv)=11
                AND z.nv NOT LIKE ''%[^0-9]%'' THEN 1 ELSE 0 END),
      SUM(CASE WHEN z.is_dec = 0
                AND (   (LEN(z.nv)=9  AND z.nv LIKE ''5[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'')
                     OR (LEN(z.nv)=12 AND z.nv LIKE ''9955[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'')
                     OR (LEN(z.nv)=13 AND z.nv LIKE ''+9955[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'') )
               THEN 1 ELSE 0 END),
      SUM(CASE WHEN z.is_dec = 0
                AND (   (LEN(z.nv)=9  AND z.nv LIKE ''322[0-9][0-9][0-9][0-9][0-9][0-9]'')
                     OR (LEN(z.nv)=10 AND z.nv LIKE ''0322[0-9][0-9][0-9][0-9][0-9][0-9]'')
                     OR (LEN(z.nv)=12 AND z.nv LIKE ''995322[0-9][0-9][0-9][0-9][0-9][0-9]'')
                     OR (LEN(z.nv)=13 AND z.nv LIKE ''+995322[0-9][0-9][0-9][0-9][0-9][0-9]'') )
               THEN 1 ELSE 0 END),
      SUM(CASE WHEN r.v LIKE ''%_@_%.__%'' AND r.v NOT LIKE ''% %'' THEN 1 ELSE 0 END),
      SUM(CASE WHEN LEN(z.nv)=22
                AND z.nv LIKE ''[Gg][Ee][0-9][0-9][A-Za-z][A-Za-z]%'' THEN 1 ELSE 0 END),
      SUM(CASE WHEN z.is_dec = 0 AND z.nv NOT LIKE ''%[^0-9]%''
                AND (   (LEN(z.nv)=16 AND LEFT(z.nv,1) IN (''4'',''5'',''6''))
                     OR (LEN(z.nv)=15 AND LEFT(z.nv,2) IN (''34'',''37'')) )
                AND l.luhn % 10 = 0
               THEN 1 ELSE 0 END),
      SUM(CASE WHEN LEN(z.nv)=7
                AND z.nv LIKE ''[A-Za-z][A-Za-z][0-9][0-9][0-9][A-Za-z][A-Za-z]''
               THEN 1 ELSE 0 END),
      -- IPv4. PARSENAME ოთხ ნაწილად ჭრის და თითოეული 0-255 უნდა იყოს:
      -- ეს `10.0.19041.1` ტიპის build-ნომრებს აცილებს. `17.0.0.0` ვერსია
      -- ფორმატით რეალურ IP-სგან განურჩეველია — იქ ნიმუშის ზღვარი მუშაობს.
      SUM(CASE WHEN LEN(r.v) BETWEEN 7 AND 15
                AND r.v NOT LIKE ''%[^0-9.]%''
                AND LEN(r.v) - LEN(REPLACE(r.v, ''.'', '''')) = 3
                AND r.v LIKE ''[0-9]%[0-9]''
                AND TRY_CAST(PARSENAME(r.v, 1) AS INT) BETWEEN 0 AND 255
                AND TRY_CAST(PARSENAME(r.v, 2) AS INT) BETWEEN 0 AND 255
                AND TRY_CAST(PARSENAME(r.v, 3) AS INT) BETWEEN 0 AND 255
                AND TRY_CAST(PARSENAME(r.v, 4) AS INT) BETWEEN 0 AND 255
               THEN 1 ELSE 0 END),
      SUM(CASE WHEN r.v LIKE ''%[A-Za-z0-9]@[A-Za-z0-9]%.[A-Za-z][A-Za-z]%''
               THEN 1 ELSE 0 END),
      SUM(CASE WHEN z.is_dec = 0
                AND z.nv LIKE ''%5[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%''
               THEN 1 ELSE 0 END)';

    DECLARE @norm NVARCHAR(MAX) = N'
    CROSS APPLY (VALUES (
        REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
            r.v, '' '', ''''), ''-'', ''''), ''('', ''''), '')'', ''''), ''.'', ''''),
        CASE WHEN LEN(r.v) - LEN(REPLACE(r.v, ''.'', '''')) = 1
                  AND r.v NOT LIKE ''%-%-%''
                  AND REPLACE(r.v, ''-'', '''') NOT LIKE ''%[^0-9.]%''
             THEN 1 ELSE 0 END
    )) AS z(nv, is_dec)
    CROSS APPLY (
        -- Luhn (ISO/IEC 7812). მარჯვნიდან ყოველი მეორე ციფრი ორმაგდება;
        -- 9-ზე მეტი ჯამი 9-ით მცირდება; საბოლოო ჯამი 10-ზე უნდა იყოფოდეს.
        -- პოზიცია i მარცხნიდან ორმაგდება, როცა (LEN - i) კენტია.
        -- -1 = შემოწმება არ ჩატარებულა (არ არის 15/16 ციფრი), ანუ % 10 <> 0.
        --
        -- ციფრი, პოზიცია და სიგრძე ჯერ d-ში გადმოდის და მხოლოდ მერე ჯამდება.
        -- პირდაპირ SUM(... z.nv ... p.i ...) Msg 8124-ს იძლევა: თუ აგრეგირებულ
        -- გამოსახულებაში გარე მითითებაა, ის ერთადერთი სვეტი უნდა იყოს იქ.
        -- გადმოტანა CROSS APPLY-ით ხდება და არა derived table-ით — derived
        -- table გარე სვეტს ვერ ხედავს, APPLY კი სწორედ ამისთვისაა.
        SELECT CASE WHEN LEN(z.nv) IN (15,16) AND z.nv NOT LIKE ''%[^0-9]%'' THEN (
                    SELECT SUM(CASE WHEN (d.ln - d.i) % 2 = 1
                                    THEN CASE WHEN d.dg * 2 > 9 THEN d.dg * 2 - 9
                                              ELSE d.dg * 2 END
                                    ELSE d.dg END)
                    FROM (VALUES (1),(2),(3),(4),(5),(6),(7),(8),
                                 (9),(10),(11),(12),(13),(14),(15),(16)) p(i)
                    CROSS APPLY (VALUES (
                        p.i, LEN(z.nv), TRY_CAST(SUBSTRING(z.nv, p.i, 1) AS INT)
                    )) d(i, ln, dg)
                    WHERE p.i <= LEN(z.nv) )
               ELSE -1 END AS luhn
    ) AS l
    WHERE r.v IS NOT NULL AND r.v <> ''''
    GROUP BY r.colname;';

    DECLARE @sch SYSNAME, @tbl SYSNAME, @ordc SYSNAME, @tbl_id INT;
    DECLARE @sql NVARCHAR(MAX), @cols NVARCHAR(MAX), @src NVARCHAR(MAX);
    DECLARE @half NVARCHAR(10) = CAST(@SampleSize / 2 AS NVARCHAR(10));
    DECLARE @full NVARCHAR(10) = CAST(@SampleSize AS NVARCHAR(10));

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT tbl_id, schema_name, table_name, order_col
        FROM #tbl ORDER BY schema_name, table_name;

    OPEN cur;
    FETCH NEXT FROM cur INTO @tbl_id, @sch, @tbl, @ordc;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- ნიმუშის წყარო. order_col-ის არსებობისას ნახევარი ცხრილის დასაწყისიდან,
        -- ნახევარი ბოლოდან — TOP N ORDER BY-ის გარეშე მხოლოდ ძველ მწკრივებს იღებს.
        SET @src = CASE WHEN @ordc IS NULL THEN
                N'(SELECT TOP (' + @full + N') * FROM ' + QUOTENAME(@sch) + N'.'
                  + QUOTENAME(@tbl) + N' WITH (NOLOCK)) s'
            ELSE
                N'(SELECT * FROM (SELECT TOP (' + @half + N') * FROM ' + QUOTENAME(@sch) + N'.'
                  + QUOTENAME(@tbl) + N' WITH (NOLOCK)) a
                   UNION ALL
                   SELECT * FROM (SELECT TOP (' + @half + N') * FROM ' + QUOTENAME(@sch) + N'.'
                  + QUOTENAME(@tbl) + N' WITH (NOLOCK) ORDER BY ' + QUOTENAME(@ordc) + N' DESC) b) s'
            END;

        -- @FastMode = 1: ცხრილის ყველა სვეტი ერთ მოთხოვნაში.
        -- @FastMode = 0: თითო სვეტი ცალკე — ნელია, სამაგიეროდ ერთი წაუკითხავი
        --                სვეტი მთელ ცხრილს არ აგდებს.
        IF @FastMode = 1
        BEGIN
            SET @cols = STUFF((
                SELECT N',(N' + QUOTENAME(c.column_name, '''') + N', LTRIM(RTRIM(CONVERT(NVARCHAR(4000), s.'
                       + QUOTENAME(c.column_name) + N'))) COLLATE Latin1_General_BIN2)'
                FROM #col c
                WHERE c.to_scan = 1 AND c.schema_name = @sch AND c.table_name = @tbl
                ORDER BY c.column_name
                FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '');

            SET @sql = N'SELECT N' + QUOTENAME(@sch, '''') + N', N' + QUOTENAME(@tbl, '''')
                     + N', r.colname, COUNT(*),' + @checks
                     + N' FROM ' + @src
                     + N' CROSS APPLY (VALUES ' + @cols + N') AS r(colname, v)'
                     + @norm;

            BEGIN TRY
                INSERT INTO #hits (schema_name, table_name, column_name, n,
                                   h_pid, h_phone, h_land, h_mail, h_iban,
                                   h_card, h_plate, h_ip, h_emb_mail, h_emb_phone)
                EXEC sp_executesql @sql;

                SET @scanned += (SELECT COUNT(*) FROM #col
                                 WHERE to_scan = 1 AND schema_name = @sch AND table_name = @tbl);
            END TRY
            BEGIN CATCH
                -- ერთი მოთხოვნა = ერთი ცხრილი, ანუ შეცდომა მთელ ცხრილს ეხება.
                -- ეს არის სწრაფი რეჟიმის ფასი; @FastMode = 0 სვეტებს ცალკე არჩევს.
                INSERT INTO #skipped (schema_name, table_name, column_name, reason, err)
                SELECT @sch, @tbl, column_name, N'ERROR',
                       LEFT(N'#' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + N': '
                            + ERROR_MESSAGE(), 400)
                FROM #col
                WHERE to_scan = 1 AND schema_name = @sch AND table_name = @tbl;
            END CATCH
        END
        ELSE
        BEGIN
            DECLARE @cln SYSNAME;
            DECLARE ccur CURSOR LOCAL FAST_FORWARD FOR
                SELECT column_name FROM #col
                WHERE to_scan = 1 AND schema_name = @sch AND table_name = @tbl
                ORDER BY column_name;
            OPEN ccur;
            FETCH NEXT FROM ccur INTO @cln;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @sql = N'SELECT N' + QUOTENAME(@sch, '''') + N', N' + QUOTENAME(@tbl, '''')
                         + N', r.colname, COUNT(*),' + @checks
                         + N' FROM ' + @src
                         + N' CROSS APPLY (VALUES (N' + QUOTENAME(@cln, '''')
                         + N', LTRIM(RTRIM(CONVERT(NVARCHAR(4000), s.' + QUOTENAME(@cln)
                         + N'))) COLLATE Latin1_General_BIN2)) AS r(colname, v)'
                         + @norm;
                BEGIN TRY
                    INSERT INTO #hits (schema_name, table_name, column_name, n,
                                       h_pid, h_phone, h_land, h_mail, h_iban,
                                       h_card, h_plate, h_ip, h_emb_mail, h_emb_phone)
                    EXEC sp_executesql @sql;
                    SET @scanned += 1;
                END TRY
                BEGIN CATCH
                    INSERT INTO #skipped (schema_name, table_name, column_name, reason, err)
                    VALUES (@sch, @tbl, @cln, N'ERROR',
                            LEFT(N'#' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + N': '
                                 + ERROR_MESSAGE(), 400));
                END CATCH
                FETCH NEXT FROM ccur INTO @cln;
            END
            CLOSE ccur; DEALLOCATE ccur;
        END

        FETCH NEXT FROM cur INTO @tbl_id, @sch, @tbl, @ordc;
    END

    CLOSE cur; DEALLOCATE cur;
    RAISERROR (N'დასკანერებული სვეტი: %d', 0, 1, @scanned) WITH NOWAIT;

    ----------------------------------------------------------------------------
    -- შეცდომის ტექსტიდან მნიშვნელობის ამოღება.
    --
    -- SQL Server-ის შეცდომა ხშირად თავად მონაცემს შეიცავს:
    --   Conversion failed when converting the varchar value 'x@y.com' to int.
    -- ეს კი არღვევს სკრიპტის მთავარ დაპირებას — რომ რეალურ მნიშვნელობას არ
    -- აბრუნებს. ბრჭყალის შემდეგ ყველაფერი იჭრება; შეცდომის ნომერი რჩება,
    -- ანუ დიაგნოსტიკა არ იკარგება.
    ----------------------------------------------------------------------------
    UPDATE #skipped
       SET err = LEFT(err, CHARINDEX('''', err) - 1) + N'[მნიშვნელობა ამოღებულია]'
     WHERE reason = N'ERROR' AND CHARINDEX('''', err) > 0;

    ----------------------------------------------------------------------------
    -- დათვლილი დამთხვევები → აღმოჩენები.
    -- ტექსტში ჩადგმულის შემოწმება მხოლოდ გრძელ სვეტს ეხება — გადაწყვეტილება
    -- აქ მიიღება, რადგან სიგრძე თითო სვეტისაა და მოთხოვნა ცხრილისა.
    ----------------------------------------------------------------------------
    INSERT INTO #find (schema_name, table_name, column_name, data_type,
                       approx_rows, category, detected_by, sampled_rows,
                       hit_pct, confidence, is_special)
    SELECT h.schema_name, h.table_name, h.column_name, c.data_type, c.approx_rows,
           d.cat, N'DATA', h.n,
           CAST(100.0 * d.hits / h.n AS DECIMAL(5,2)),
           CASE WHEN 100.0 * d.hits / h.n >= 80 THEN 95
                WHEN 100.0 * d.hits / h.n >= 40 THEN 80
                ELSE 60 END,
           0
    FROM #hits h
    JOIN #col c ON c.schema_name = h.schema_name
               AND c.table_name  = h.table_name
               AND c.column_name = h.column_name
    CROSS APPLY (VALUES
            (N'პირადი ნომერი',        h.h_pid),
            (N'ტელეფონი',             h.h_phone),
            (N'ტელეფონი',             h.h_land),
            (N'ელფოსტა',              h.h_mail),
            (N'ფინანსური',            h.h_iban),
            (N'ფინანსური',            h.h_card),
            (N'ავტომობილი',           h.h_plate),
            (N'ონლაინ იდენტიფიკატორი', h.h_ip),
            (N'ელფოსტა (ტექსტში)',
                CASE WHEN c.max_length = -1 OR c.max_length > 100 THEN h.h_emb_mail ELSE 0 END),
            (N'ტელეფონი (ტექსტში)',
                CASE WHEN c.max_length = -1 OR c.max_length > 100 THEN h.h_emb_phone ELSE 0 END)
         ) d(cat, hits)
    WHERE h.n > 0
      AND d.hits > 0
      -- პროცენტული წესი მხოლოდ საკმარისად დიდ ნიმუშზე ენდობა. ერთმწკრივიან
      -- ცხრილში ერთი დამთხვევა „100%"-ია და ყოველთვის გაივლიდა — სწორედ ასე
      -- ხვდებოდა ანგარიშში `AWBuildVersion.Database Version` IP მისამართად.
      AND (   (h.n >= @MinSampleForPct AND 100.0 * d.hits / h.n >= @MinHitPct)
           OR d.hits >= @MinAbsHits );
END
--------------------------------------------------------------------------------
-- 6. სახელით ნაპოვნის დამატება
--------------------------------------------------------------------------------
INSERT INTO #find (schema_name, table_name, column_name, data_type, approx_rows,
                   category, detected_by, sampled_rows, hit_pct, confidence, is_special)
SELECT c.schema_name, c.table_name, c.column_name, c.data_type, c.approx_rows,
       c.name_category, N'NAME', 0, NULL, c.name_confidence,
       -- პატერნების ცხრილიდან გადმოტანილი ფლაგი.
       -- კატეგორიის ტექსტში ⚠-ის ძებნა (LIKE N'%⚠%') აქ არ გამოდგება:
       -- U+26A0-ს collation-ში სორტირების წონა არ აქვს, LIKE მას ყლაპავს
       -- და პატერნი ყველა სტრიქონს ემთხვევა — ყველაფერი სპეციალური ხდებოდა.
       c.name_is_special
FROM #col c
WHERE c.name_category IS NOT NULL
  AND c.name_confidence >= @MinNameConfidence;

--------------------------------------------------------------------------------
-- 6a. აღმოჩენების დედუპლიკაცია
--     ერთი მწკრივი = ერთი სვეტი + ერთი კატეგორია, მიუხედავად იმისა, სახელით
--     მოიძებნა, მონაცემით თუ ორივეთი. სამივე ანგარიში ამ ცხრილიდან იკითხება.
--------------------------------------------------------------------------------
INSERT INTO #agg (schema_name, table_name, column_name, data_type, approx_rows,
                  category, by_name, by_data, hit_pct, conf, is_special)
SELECT schema_name, table_name, column_name, data_type, approx_rows, category,
       MAX(CASE WHEN detected_by = 'NAME' THEN 1 ELSE 0 END),
       MAX(CASE WHEN detected_by = 'DATA' THEN 1 ELSE 0 END),
       MAX(hit_pct),
       MAX(confidence),
       MAX(CAST(is_special AS INT))
FROM #find
GROUP BY schema_name, table_name, column_name, data_type, approx_rows, category;

--------------------------------------------------------------------------------
-- 6b. შედეგი #0 — გაშვების წარმომავლობა
--     აღმოჩენების სია მტკიცებულებაა მხოლოდ მაშინ, თუ ცნობილია რა, სად, როდის
--     და რომელი პარამეტრებით შემოწმდა. ეს მწკრივი ანგარიშთან ერთად ინახება.
--------------------------------------------------------------------------------
SELECT
    N'0. გაშვება' AS [ანგარიში],
    @@SERVERNAME AS [სერვერი],
    DB_NAME()    AS [ბაზა],
    CONVERT(NVARCHAR(19), SYSDATETIME(), 120) AS [დრო],
    @ScriptVersion AS [სკრიპტის ვერსია],
    SUSER_SNAME() AS [მომხმარებელი],
    N'SampleSize='        + CAST(@SampleSize        AS NVARCHAR(10))
  + N'; MinHitPct='       + CAST(@MinHitPct         AS NVARCHAR(10))
  + N'; MinSampleForPct=' + CAST(@MinSampleForPct   AS NVARCHAR(10))
  + N'; MinAbsHits='      + CAST(@MinAbsHits        AS NVARCHAR(10))
  + N'; ScanData='        + CAST(@ScanData          AS NVARCHAR(1))
  + N'; ScanAllStringCols=' + CAST(@ScanAllStringCols AS NVARCHAR(1))
  + N'; MaxColumnsToScan=' + CAST(@MaxColumnsToScan AS NVARCHAR(10))
  + N'; FastMode='        + CAST(@FastMode          AS NVARCHAR(1))
  + N'; MinNameConfidence=' + CAST(@MinNameConfidence AS NVARCHAR(10))
    AS [კონფიგურაცია];

--------------------------------------------------------------------------------
-- 7. შედეგი #1 — კონსოლიდირებული აღმოჩენები
--------------------------------------------------------------------------------
SELECT
    N'1. აღმოჩენები' AS [ანგარიში],
    a.schema_name AS [სქემა], a.table_name AS [ცხრილი], a.column_name AS [სვეტი],
    a.data_type AS [ტიპი], a.approx_rows AS [მწკრივი], a.category AS [კატეგორია],
    CASE WHEN a.by_name = 1 AND a.by_data = 1 THEN N'სახელი+მონაცემი'
         WHEN a.by_data = 1 THEN N'მონაცემი'
         ELSE N'სახელი' END AS [აღმოჩენის წყარო],
    a.hit_pct AS [დამთხვევა %],
    CASE WHEN a.by_name = 1 AND a.by_data = 1 THEN 99 ELSE a.conf END AS [დარწმუნება],
    CASE WHEN a.is_special = 1 THEN N'დიახ' ELSE N'' END AS [სპეციალური კატეგორია],
    CASE WHEN a.is_special = 1 OR (a.by_name = 1 AND a.by_data = 1) THEN N'მაღალი'
         WHEN a.conf >= 80 THEN N'საშუალო'
         ELSE N'დაბალი' END AS [რისკი],
    -- FK-ის ეჭვი მხოლოდ მაშინ ითქმის, თუ მონაცემმა თავად ვერაფერი დაადასტურა
    RTRIM(
        CASE WHEN c.is_likely_fk = 1 AND a.by_data = 0
             THEN N'სავარაუდოდ FK — შეამოწმე ხელით. ' ELSE N'' END
      + CASE WHEN c.name_needs_review = 1
             THEN N'კატეგორია კონტექსტზეა დამოკიდებული — შეამოწმე ხელით.' ELSE N'' END
    ) AS [შენიშვნა]
FROM #agg a
LEFT JOIN #col c
       ON c.schema_name = a.schema_name
      AND c.table_name  = a.table_name
      AND c.column_name = a.column_name
ORDER BY a.is_special DESC,
         CASE WHEN a.by_name = 1 AND a.by_data = 1 THEN 0 ELSE 1 END,
         a.conf DESC, a.approx_rows DESC;

--------------------------------------------------------------------------------
-- 8. შედეგი #2 — შეჯამება კატეგორიების მიხედვით
--------------------------------------------------------------------------------
SELECT
    N'2. შეჯამება' AS [ანგარიში],
    category AS [კატეგორია],
    COUNT(DISTINCT schema_name + '.' + table_name) AS [ცხრილი],
    -- სვეტი სრული გზით ითვლება: ორ სხვადასხვა ცხრილში `email` ორია, არა ერთი
    COUNT(DISTINCT schema_name + '.' + table_name + '.' + column_name) AS [სვეტი],
    SUM(is_special) AS [სპეციალური]
FROM #agg
GROUP BY category
ORDER BY [ცხრილი] DESC, [კატეგორია];

--------------------------------------------------------------------------------
-- 9. შედეგი #3 — RoPA-ს ნახევრადმზა სტრიქონები
--    დამუშავების აღრიცხვის რეესტრისთვის: ცხრილი → მონაცემთა კატეგორიები
--------------------------------------------------------------------------------
SELECT
    N'3. RoPA დრაფტი' AS [ანგარიში],
    schema_name + '.' + table_name AS [დამუშავების ობიექტი],
    STUFF((
        SELECT DISTINCT ', ' + f2.category
        FROM #agg f2
        WHERE f2.schema_name = f.schema_name AND f2.table_name = f.table_name
        ORDER BY ', ' + f2.category
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '') AS [მონაცემთა კატეგორიები],
    -- „ჩანაწერი" და არა „სუბიექტი": ტრანზაქციების ცხრილში 1M მწკრივი
    -- შეიძლება 8000 ადამიანს ეხებოდეს. სუბიექტების რაოდენობა აქედან არ დგინდება.
    MAX(f.approx_rows) AS [ჩანაწერი (მიახლ.)],
    CASE WHEN MAX(f.is_special) = 1
         THEN N'საჭიროა გაძლიერებული საფუძველი + DPIA'
         ELSE N'სტანდარტული' END AS [შენიშვნა]
FROM #agg f
GROUP BY schema_name, table_name
ORDER BY [ჩანაწერი (მიახლ.)] DESC, [დამუშავების ობიექტი];

--------------------------------------------------------------------------------
-- 10. შედეგი #4 — მოცვა
--     აუდიტს სჭირდება მტკიცებულება იმისა, თუ რა შემოწმდა — არა მხოლოდ
--     ის, რა მოიძებნა. ცარიელი შედეგი შეიძლება ნიშნავდეს „PII არ არის"
--     ან „ვერ წავიკითხე"; ეს ორი აქ ერთმანეთისგან განირჩევა.
--------------------------------------------------------------------------------
SELECT
    N'4. მოცვა' AS [ანგარიში],
    (SELECT COUNT(DISTINCT schema_name + '.' + table_name) FROM #col) AS [ცხრილი სულ],
    (SELECT COUNT(*) FROM #col)                                       AS [სვეტი სულ],
    (SELECT COUNT(*) FROM #col WHERE approx_rows = 0)                 AS [ცარიელი ცხრილი],
    @scanned                                                          AS [დასკანერებული სვეტი],
    (SELECT COUNT(*) FROM #skipped WHERE reason = N'COMPUTED')        AS [გამოტოვებული: გამოთვლადი],
    (SELECT COUNT(*) FROM #skipped WHERE reason = N'ERROR')           AS [გამოტოვებული: შეცდომა],
    CASE WHEN @ScanData = 0 THEN N'მონაცემი არ სკანირებულა (@ScanData = 0)'
         WHEN EXISTS (SELECT 1 FROM #skipped WHERE reason = N'ERROR')
              THEN N'⚠ ნაწილი სვეტებისა ვერ წაიკითხა — იხ. ანგარიში 5'
         ELSE N'სრული' END AS [სტატუსი];

--------------------------------------------------------------------------------
-- 11. შედეგი #5 — გამოტოვებული სვეტები
--------------------------------------------------------------------------------
SELECT
    N'5. გამოტოვებული' AS [ანგარიში],
    schema_name AS [სქემა], table_name AS [ცხრილი], column_name AS [სვეტი],
    CASE reason WHEN N'COMPUTED' THEN N'გამოთვლადი სვეტი'
                ELSE N'შეცდომა' END AS [მიზეზი],
    err AS [დეტალი]
FROM #skipped
ORDER BY reason, schema_name, table_name, column_name;

--------------------------------------------------------------------------------
-- 12. დასუფთავება
--------------------------------------------------------------------------------
-- DROP TABLE #col; DROP TABLE #find; DROP TABLE #agg; DROP TABLE #skipped;
