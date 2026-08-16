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
DECLARE @SampleSize      INT           = 500;   -- რამდენი მწკრივი თითო სვეტზე
DECLARE @MinHitPct       DECIMAL(5,2)  = 5.00;  -- ზღვარი: მაჩვენებელი ამაზე ქვემოთ იგნორდება
DECLARE @MinAbsHits      INT           = 3;     -- აბსოლუტური ზღვარი: ამდენი დამთხვევა ყოველთვის
                                                -- აისახება, პროცენტის მიუხედავად. კომპლაიენსში
                                                -- მნიშვნელოვანია არსებობა, არა გავრცელება —
                                                -- ერთი IBAN არასწორ სვეტში უკვე ინციდენტია.
DECLARE @ScanData        BIT           = 1;     -- 0 = მხოლოდ სახელების ანალიზი (ძალიან სწრაფი)
DECLARE @ScanAllStringCols BIT         = 1;     -- 1 = ყველა ტექსტური სვეტი, არა მხოლოდ სახელით ნაპოვნი
DECLARE @MaxColumnsToScan INT          = 3000;  -- დაცვა უზარმაზარ ბაზებზე
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
    name_category   NVARCHAR(40)  NULL,
    name_confidence TINYINT       NOT NULL DEFAULT 0,
    name_is_special BIT           NOT NULL DEFAULT 0
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
       (N'პირადი ნომერი',        N'%personal%num%',              90, 0),
       (N'პირადი ნომერი',        N'%personal%no%',               90, 0),
       -- 40: `PersonID` / `SalesPersonID` ტიპის FK-ებს იჭერს ისევე, როგორც
       -- ნამდვილ `personal_id`-ს. ნამდვილს მონაცემის ეტაპი დაადასტურებს (11 ციფრი).
       (N'პირადი ნომერი',        N'%pers%id%',                   40, 0),
       (N'პირადი ნომერი',        N'%piradi%',                    90, 0),
       (N'პირადი ნომერი',        N'%pid%',                       60, 0),
       (N'პირადი ნომერი',        N'%id_number%',                 85, 0),
       (N'პირადი ნომერი',        N'%identity%',                  70, 0),
       (N'პირადი ნომერი',        N'%sagadasakhado%',             70, 0),
       (N'პირადი ნომერი',        N'%tax%id%',                    70, 0),

       (N'სახელი/გვარი',         N'%first%name%',                90, 0),
       (N'სახელი/გვარი',         N'%last%name%',                 90, 0),
       (N'სახელი/გვარი',         N'%full%name%',                 90, 0),
       (N'სახელი/გვარი',         N'%surname%',                   90, 0),
       (N'სახელი/გვარი',         N'%gvari%',                     90, 0),
       (N'სახელი/გვარი',         N'%saxeli%',                    85, 0),
       (N'სახელი/გვარი',         N'%sakheli%',                   85, 0),
       (N'სახელი/გვარი',         N'%patronymic%',                80, 0),

       (N'ტელეფონი',             N'%phone%',                     90, 0),
       (N'ტელეფონი',             N'%mobile%',                    85, 0),
       (N'ტელეფონი',             N'%tel%',                       60, 0),
       (N'ტელეფონი',             N'%mob_nom%',                   85, 0),

       (N'ელფოსტა',              N'%email%',                     95, 0),
       (N'ელფოსტა',              N'%e_mail%',                    95, 0),

       (N'მისამართი',            N'%address%',                   85, 0),
       (N'მისამართი',            N'%misamart%',                  90, 0),
       (N'მისამართი',            N'%street%',                    70, 0),
       (N'მისამართი',            N'%postal%',                    60, 0),
       (N'მისამართი',            N'%zip%',                       55, 0),

       (N'დაბადების თარიღი',     N'%birth%',                     90, 0),
       (N'დაბადების თარიღი',     N'%dabadeb%',                   90, 0),
       (N'დაბადების თარიღი',     N'%dob%',                       70, 0),

       (N'დოკუმენტი',            N'%passport%',                  90, 0),
       (N'დოკუმენტი',            N'%pasport%',                   90, 0),
       (N'დოკუმენტი',            N'%driver%lic%',                85, 0),
       (N'დოკუმენტი',            N'%mowmoba%',                   65, 0),

       (N'ფინანსური',            N'%iban%',                      95, 0),
       (N'ფინანსური',            N'%account%num%',               75, 0),
       (N'ფინანსური',            N'%card%num%',                  90, 0),
       (N'ფინანსური',            N'%bank%',                      60, 0),
       (N'ფინანსური',            N'%salary%',                    70, 0),
       (N'ფინანსური',            N'%xelfas%',                    75, 0),

       (N'ავტომობილი',           N'%plate%',                     80, 0),
       (N'ავტომობილი',           N'%vin%',                       70, 0),

       -- ონლაინ იდენტიფიკატორი კანონით პერსონალური მონაცემია.
       -- ყურადღება: LIKE-ში `_` ერთი ნებისმიერი სიმბოლოა, ანუ `%ip_addr%`
       -- იჭერს `ip_addr`-საც და `ip-addr`-საც, მაგრამ `ipaddress`-ს — არა.
       -- ამიტომ ორივე ვარიანტი ცალკეა ჩაწერილი.
       (N'ონლაინ იდენტიფიკატორი', N'%ip_addr%',                  85, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%ipaddr%',                   85, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%client_ip%',                85, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%remote_ip%',                85, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%mac_addr%',                 85, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%macaddr%',                  85, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%imei%',                     90, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%device%id%',                75, 0),
       (N'ონლაინ იდენტიფიკატორი', N'%session%id%',               70, 0),

       (N'გეოლოკაცია',           N'%latitude%',                  70, 0),
       (N'გეოლოკაცია',           N'%longitude%',                 70, 0),
       (N'გეოლოკაცია',           N'%gps%',                       70, 0),

       -- ↓↓↓ სპეციალური კატეგორიის მონაცემები ↓↓↓
       (N'ჯანმრთელობა ⚠',        N'%diagnos%',                   90, 1),
       (N'ჯანმრთელობა ⚠',        N'%icd%',                       75, 1),
       (N'ჯანმრთელობა ⚠',        N'%blood%',                     80, 1),
       (N'ჯანმრთელობა ⚠',        N'%disabil%',                   85, 1),
       (N'ჯანმრთელობა ⚠',        N'%shshm%',                     85, 1),
       (N'ჯანმრთელობა ⚠',        N'%health%',                    75, 1),
       (N'ჯანმრთელობა ⚠',        N'%medical%',                   80, 1),
       (N'ჯანმრთელობა ⚠',        N'%janmrtel%',                  90, 1),

       (N'ბიომეტრია ⚠',          N'%fingerprint%',               90, 1),
       (N'ბიომეტრია ⚠',          N'%biometr%',                   90, 1),
       (N'ბიომეტრია ⚠',          N'%face%id%',                   70, 1),
       -- 40: პროდუქტის/დოკუმენტის ფოტოს სვეტებს ისევე იჭერს, როგორც ადამიანისას.
       (N'ბიომეტრია ⚠',          N'%photo%',                     40, 1),

       (N'სენსიტიური ⚠',         N'%religio%',                   85, 1),
       (N'სენსიტიური ⚠',         N'%ethnic%',                    85, 1),
       (N'სენსიტიური ⚠',         N'%nationalit%',                70, 1),
       (N'სენსიტიური ⚠',         N'%citizenship%',               60, 1),
       (N'სენსიტიური ⚠',         N'%politic%',                   80, 1),
       (N'სენსიტიური ⚠',         N'%criminal%',                  85, 1),
       (N'სენსიტიური ⚠',         N'%nasamartl%',                 90, 1),
       (N'სენსიტიური ⚠',         N'%sex%',                       55, 1),
       (N'სენსიტიური ⚠',         N'%trade%union%',               80, 1)
    ) v(category, pattern, conf, is_special)
),
best AS (
    SELECT c.col_id, p.category, p.conf, p.is_special,
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
       name_is_special = b.is_special
FROM #col c
JOIN best b ON b.col_id = c.col_id AND b.rn = 1;

--------------------------------------------------------------------------------
-- 5. ეტაპი 2 — მონაცემის შერჩევითი სკანირება
--------------------------------------------------------------------------------
DECLARE @scanned INT = 0;

IF @ScanData = 1
BEGIN
    -- გამოთვლადი სვეტი მონაცემით არ სკანირდება: თითო მწკრივზე გამოსახულების
    -- იძულებით გამოთვლას ნიშნავს. სახელის ევრისტიკა მასზე მაინც მუშაობს.
    -- ჩამონათვალი ემთხვევა კურსორის პირობას — ანუ ესენი სხვა შემთხვევაში
    -- დასკანერდებოდა.
    INSERT INTO #skipped (schema_name, table_name, column_name, reason, err)
    SELECT schema_name, table_name, column_name, N'COMPUTED',
           N'გამოთვლადი სვეტი — მონაცემი არ წაკითხულა'
    FROM #col
    WHERE is_computed = 1
      AND approx_rows > 0
      AND (   (is_text = 1 AND @ScanAllStringCols = 1)
           OR name_category IS NOT NULL
           OR is_numeric_id = 1 );

    DECLARE @sch SYSNAME, @tbl SYSNAME, @cln SYSNAME, @dt SYSNAME,
            @rows BIGINT, @ncat NVARCHAR(40), @nconf TINYINT, @maxlen INT;
    DECLARE @sql NVARCHAR(MAX);
    DECLARE @n INT, @h_pid INT, @h_phone INT, @h_mail INT,
            @h_iban INT, @h_card INT, @h_plate INT,
            @h_emb_mail INT, @h_emb_phone INT,
            @h_land INT, @h_ip INT;
    DECLARE @is_long BIT;

    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT TOP (@MaxColumnsToScan)
               schema_name, table_name, column_name, data_type,
               approx_rows, name_category, name_confidence, max_length
        FROM #col
        WHERE approx_rows > 0
          AND is_computed = 0
          AND (   (is_text = 1 AND @ScanAllStringCols = 1)
               OR name_category IS NOT NULL
               OR is_numeric_id = 1 )
        ORDER BY name_confidence DESC, approx_rows DESC, schema_name, table_name, column_name;

    OPEN cur;
    FETCH NEXT FROM cur INTO @sch, @tbl, @cln, @dt, @rows, @ncat, @nconf, @maxlen;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- გრძელი ტექსტური სვეტი — მხოლოდ ასეთში ვეძებთ ტექსტში ჩადგმულ PII-ს.
        -- max_length ბაიტებშია (nvarchar(50) → 100), -1 კი MAX ტიპს ნიშნავს.
        SET @is_long = CASE WHEN @maxlen = -1 OR @maxlen > 100 THEN 1 ELSE 0 END;

        -- v ფიქსირდება Latin1_General_BIN2-ზე, რომ შედეგი სერვერის collation-ზე
        -- არ იყოს დამოკიდებული. BIN2 რეგისტრმგრძნობიარეა, ამიტომ ასოთა
        -- დიაპაზონები ორივე რეგისტრით წერია ([A-Za-z]) და არა [A-Z]-ით.
        --
        -- nv = ნორმალიზებული მნიშვნელობა: მოშორებულია გამყოფები, რომლითაც
        -- ციფრულ ფორმატებს რეალურ ბაზებში წერენ —
        --   ტელეფონი „555 12 34 56", „(555) 12-34-56", „+995 555 123456"
        --   პირადი ნომერი „01001 012345"
        --   ბარათი „4111-1111-1111-1111"
        -- ელფოსტასა და IBAN-ს nv არ ეხება: იქ წერტილი და შუალედი
        -- თავად ფორმატის ნაწილია, არა შემთხვევითი გამყოფი.
        SET @sql = N'
            SELECT @n = COUNT(*),
              @h_pid   = SUM(CASE WHEN is_dec = 0
                                   AND LEN(nv)=11 AND nv NOT LIKE ''%[^0-9]%'' THEN 1 ELSE 0 END),
              @h_phone = SUM(CASE WHEN is_dec = 0
                                   AND (   (LEN(nv)=9  AND nv LIKE ''5[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'')
                                        OR (LEN(nv)=12 AND nv LIKE ''9955[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'')
                                        OR (LEN(nv)=13 AND nv LIKE ''+9955[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'') )
                                  THEN 1 ELSE 0 END),
              -- სტაციონარული, თბილისი: 32 + 7 ციფრი, ადგილობრივი ნაწილი 2-ით იწყება
              @h_land  = SUM(CASE WHEN is_dec = 0
                                   AND (   (LEN(nv)=9  AND nv LIKE ''322[0-9][0-9][0-9][0-9][0-9][0-9]'')
                                        OR (LEN(nv)=10 AND nv LIKE ''0322[0-9][0-9][0-9][0-9][0-9][0-9]'')
                                        OR (LEN(nv)=12 AND nv LIKE ''995322[0-9][0-9][0-9][0-9][0-9][0-9]'')
                                        OR (LEN(nv)=13 AND nv LIKE ''+995322[0-9][0-9][0-9][0-9][0-9][0-9]'') )
                                  THEN 1 ELSE 0 END),
              -- 16 ციფრი 4/5/6-ით (Visa/MC/Discover) ან 15 ციფრი 34/37-ით (Amex)
              @h_card  = SUM(CASE WHEN is_dec = 0 AND nv NOT LIKE ''%[^0-9]%''
                                   AND (   (LEN(nv)=16 AND LEFT(nv,1) IN (''4'',''5'',''6''))
                                        OR (LEN(nv)=15 AND LEFT(nv,2) IN (''34'',''37'')) )
                                  THEN 1 ELSE 0 END),
              -- IPv4: მხოლოდ ციფრი და წერტილი, ზუსტად სამი წერტილი.
              -- v-ზე მოწმდება და არა nv-ზე — ნორმალიზაცია წერტილს შლის.
              @h_ip    = SUM(CASE WHEN LEN(v) BETWEEN 7 AND 15
                                   AND v NOT LIKE ''%[^0-9.]%''
                                   AND LEN(v) - LEN(REPLACE(v, ''.'', '''')) = 3
                                   AND v LIKE ''[0-9]%[0-9]''
                                  THEN 1 ELSE 0 END),
              @h_plate = SUM(CASE WHEN LEN(nv)=7
                                   AND nv LIKE ''[A-Za-z][A-Za-z][0-9][0-9][0-9][A-Za-z][A-Za-z]''
                                   THEN 1 ELSE 0 END),
              @h_mail  = SUM(CASE WHEN v LIKE ''%_@_%.__%'' AND v NOT LIKE ''% %'' THEN 1 ELSE 0 END),
              -- nv-ზე: IBAN-ს ბლოკებად წერენ — ''GE29 NB00 0000 0101 9049 17''
              @h_iban  = SUM(CASE WHEN LEN(nv)=22
                                   AND nv LIKE ''[Gg][Ee][0-9][0-9][A-Za-z][A-Za-z]%''
                                  THEN 1 ELSE 0 END),
              -- ტექსტში ჩადგმული: მთელი მნიშვნელობა კი არა, მისი ნაწილი ემთხვევა
              @h_emb_mail  = SUM(CASE WHEN v LIKE ''%[A-Za-z0-9]@[A-Za-z0-9]%.[A-Za-z][A-Za-z]%''
                                      THEN 1 ELSE 0 END),
              @h_emb_phone = SUM(CASE WHEN is_dec = 0
                                       AND nv LIKE ''%5[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]%''
                                      THEN 1 ELSE 0 END)
            FROM (
                SELECT v,
                       REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                           v, '' '', ''''), ''-'', ''''), ''('', ''''), '')'', ''''), ''.'', '''') AS nv,
                       -- ათწილადი: მხოლოდ ციფრი, ზუსტად ერთი წერტილი,
                       -- სურვილისამებრ ერთი მინუსი. ნორმალიზაცია წერტილს შლის და
                       -- 5123456.78 ცხრაციფრიან „მობილურად" იქცეოდა — ეს ფლაგი ამას აჩერებს.
                       CASE WHEN LEN(v) - LEN(REPLACE(v, ''.'', '''')) = 1
                                 AND v NOT LIKE ''%-%-%''
                                 AND REPLACE(v, ''-'', '''') NOT LIKE ''%[^0-9.]%''
                            THEN 1 ELSE 0 END AS is_dec
                FROM (
                    SELECT TOP (' + CAST(@SampleSize AS NVARCHAR(10)) + N')
                           LTRIM(RTRIM(CONVERT(NVARCHAR(4000), ' + QUOTENAME(@cln) + N')))
                               COLLATE Latin1_General_BIN2 AS v
                    FROM ' + QUOTENAME(@sch) + N'.' + QUOTENAME(@tbl) + N' WITH (NOLOCK)
                    WHERE ' + QUOTENAME(@cln) + N' IS NOT NULL
                ) y
                WHERE v <> ''''
            ) x;';

        BEGIN TRY
            EXEC sp_executesql @sql,
                 N'@n INT OUTPUT, @h_pid INT OUTPUT, @h_phone INT OUTPUT,
                   @h_mail INT OUTPUT, @h_iban INT OUTPUT, @h_card INT OUTPUT,
                   @h_plate INT OUTPUT, @h_emb_mail INT OUTPUT,
                   @h_emb_phone INT OUTPUT, @h_land INT OUTPUT,
                   @h_ip INT OUTPUT',
                 @n=@n OUTPUT, @h_pid=@h_pid OUTPUT, @h_phone=@h_phone OUTPUT,
                 @h_mail=@h_mail OUTPUT, @h_iban=@h_iban OUTPUT, @h_card=@h_card OUTPUT,
                 @h_plate=@h_plate OUTPUT, @h_emb_mail=@h_emb_mail OUTPUT,
                 @h_emb_phone=@h_emb_phone OUTPUT, @h_land=@h_land OUTPUT,
                 @h_ip=@h_ip OUTPUT;
        END TRY
        BEGIN CATCH
            -- უფლების ან ტიპის პრობლემა. სვეტს ვტოვებთ, მაგრამ ჩუმად აღარ —
            -- გამოტოვებული სვეტი ანგარიშში ცალკე გამოდის.
            SET @n = 0;
            INSERT INTO #skipped (schema_name, table_name, column_name, reason, err)
            VALUES (@sch, @tbl, @cln, N'ERROR', LEFT(ERROR_MESSAGE(), 400));
        END CATCH

        IF ISNULL(@n,0) > 0
        BEGIN
            INSERT INTO #find (schema_name, table_name, column_name, data_type,
                               approx_rows, category, detected_by, sampled_rows,
                               hit_pct, confidence, is_special)
            SELECT @sch, @tbl, @cln, @dt, @rows, d.cat, N'DATA', @n,
                   CAST(100.0 * d.hits / @n AS DECIMAL(5,2)),
                   CASE WHEN 100.0 * d.hits / @n >= 80 THEN 95
                        WHEN 100.0 * d.hits / @n >= 40 THEN 80
                        ELSE 60 END,
                   0
            FROM (VALUES
                    (N'პირადი ნომერი', ISNULL(@h_pid,0)),
                    (N'ტელეფონი',      ISNULL(@h_phone,0)),
                    (N'ტელეფონი',      ISNULL(@h_land,0)),
                    (N'ონლაინ იდენტიფიკატორი', ISNULL(@h_ip,0)),
                    (N'ელფოსტა',       ISNULL(@h_mail,0)),
                    (N'ფინანსური',     ISNULL(@h_iban,0)),
                    (N'ფინანსური',     ISNULL(@h_card,0)),
                    (N'ავტომობილი',    ISNULL(@h_plate,0)),
                    -- ცალკე კატეგორიები: ტექსტში ჩადგმულ PII-ს განსხვავებული
                    -- მასკირება და სამართლებრივი მოპყრობა სჭირდება.
                    -- მხოლოდ გრძელ ტექსტურ სვეტებზე ითვლება.
                    (N'ელფოსტა (ტექსტში)',
                        CASE WHEN @is_long = 1 THEN ISNULL(@h_emb_mail,0)  ELSE 0 END),
                    (N'ტელეფონი (ტექსტში)',
                        CASE WHEN @is_long = 1 THEN ISNULL(@h_emb_phone,0) ELSE 0 END)
                 ) d(cat, hits)
            WHERE d.hits > 0
              AND (   100.0 * d.hits / @n >= @MinHitPct
                   OR d.hits >= @MinAbsHits );
        END

        SET @scanned += 1;
        FETCH NEXT FROM cur INTO @sch, @tbl, @cln, @dt, @rows, @ncat, @nconf, @maxlen;
    END

    CLOSE cur; DEALLOCATE cur;
    RAISERROR (N'დასკანერებული სვეტი: %d', 0, 1, @scanned) WITH NOWAIT;
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
    CASE WHEN c.is_likely_fk = 1 AND a.by_data = 0
         THEN N'სავარაუდოდ FK — შეამოწმე ხელით'
         ELSE N'' END AS [შენიშვნა]
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
