# pii-scan-ge

**MS SQL Server-ის ბაზაში პერსონალური მონაცემების აღმოჩენის სკრიპტი — ქართული კონტექსტისთვის.**

ერთი `.sql` ფაილი. დამოკიდებულებების გარეშე. ბაზაში არაფერს წერს.

---

## რას აკეთებს

„პერსონალურ მონაცემთა დაცვის შესახებ" საქართველოს კანონი (ძალაშია 2024 წლის 1 მარტიდან) ავალდებულებს ორგანიზაციას იცოდეს **რა პერსონალურ მონაცემს ამუშავებს და სად ინახავს**. პრაქტიკაში პასუხი ხშირად არავინ იცის — ბაზა 10 წელია იზრდება, დოკუმენტაცია არ არსებობს.

ეს სკრიპტი პასუხობს კითხვას „სად გვაქვს PII?" ორ ეტაპად:

**ეტაპი 1 — სვეტის სახელის ანალიზი.**
სკანირდება `sys.columns` და მოწმდება ~80 პატერნზე. ქართული ტრანსლიტიც (`piradi`, `gvari`, `misamart`, `janmrtel`, `nasamartl`) და ინგლისურიც. ცალკე კატეგორიაა **ონლაინ იდენტიფიკატორი** — `ip_addr`, `ipaddress`, `client_ip`, `mac_addr`, `imei`, `device_id`, `session_id` — რომელიც კანონით პერსონალურ მონაცემად ითვლება. მონაცემს არ კითხულობს — წამებში მუშაობს.

**ეტაპი 2 — მონაცემის შერჩევითი სკანირება.**
თითო **ცხრილიდან** `TOP 500` მწკრივი — ერთი გავლა, სვეტები `CROSS APPLY (VALUES …)`-ით ვერტიკალურად იშლება. 40-სვეტიან ცხრილს ერთი მოთხოვნა ხვდება და არა 40. მწკრივები ორივე ბოლოდან აიღება, რომ ნიმუშში მხოლოდ ძველი ჩანაწერები არ მოხვდეს.

`@FastMode = 0` ძველ ქცევას აბრუნებს — ერთი მოთხოვნა თითო სვეტზე. ნელია, სამაგიეროდ ერთი წაუკითხავი სვეტი მთელ ცხრილს არ აგდებს.

პატერნები:

| ტიპი | პატერნი |
|---|---|
| პირადი ნომერი | 11 ციფრი |
| მობილური | `5XXXXXXXX` / `995...` / `+995...` |
| სტაციონარული | `322XXXXXX` / `0322...` / `995322...` / `+995322...` (თბილისი) |
| ელფოსტა | `%_@_%.__%` |
| IBAN | `GE` + 2 ციფრი + 2 ასო, სულ 22 სიმბოლო (შუალედები დასაშვებია) |
| ბარათი | 16 ციფრი 4/5/6-ით, ან 15 ციფრი 34/37-ით (Amex) — **+ Luhn** |
| სახ. ნომერი | `AA000AA` |
| IP მისამართი | IPv4 — მხოლოდ ციფრი და სამი წერტილი |
| ელფოსტა (ტექსტში) | ჩადგმული `%x@y.zz%` — მხოლოდ გრძელ სვეტებში |
| ტელეფონი (ტექსტში) | ჩადგმული `5XXXXXXXX` — მხოლოდ გრძელ სვეტებში |

**ფორმატები ჯერ ნორმალიზდება** — შუალედი, დეფისი, ფრჩხილი და წერტილი შემოწმებამდე იშლება. ამიტომ იჭერს `555 12 34 56`-საც, `(555) 12-34-56`-საც, `+995 555 123456`-საც, `01001 012345`-საც, `4111-1111-1111-1111`-საც და `GE29 NB00 0000 0101 9049 17`-საც, არა მხოლოდ სუფთა ჩანაწერს.

გამონაკლისი ორია: **ელფოსტა** და **IP მისამართი** საწყის მნიშვნელობაზე მოწმდება, რადგან იქ წერტილი თავად ფორმატის ნაწილია.

**შედეგი სერვერის collation-ზე არ არის დამოკიდებული.** ნიმუში `Latin1_General_BIN2`-ზეა ფიქსირებული, ანუ ერთი და იგივე ბაზა სხვადასხვა სერვერზე ერთსა და იმავე პასუხს იძლევა. სახელების ეტაპზე ტოლი ქულების შემთხვევაში კატეგორია ანბანურად ირჩევა — გაშვებებს შორის შედეგი არ ცურავს.

**ათწილადი ტელეფონად არ ჩაითვლება.** წერტილის მოშორება `5123456.78`-ს ცხრაციფრიან „მობილურად" აქცევდა და ფულადი სვეტები ცრუ დადებითებს აწარმოებდა. ამიტომ მნიშვნელობა, რომელიც სუფთა ათწილადია (მხოლოდ ციფრი, ზუსტად ერთი წერტილი, სურვილისამებრ მინუსი), ციფრული ფორმატების შემოწმებიდან გამოირიცხება.

ბოლო ორი პატერნი **თავისუფალ ტექსტში ჩადგმულ** მონაცემს ეძებს — „დაურეკეთ 555123456-ზე" `Comment`-ის სვეტში. მუშაობს მხოლოდ გრძელ სვეტებზე (`max_length > 100` ან `MAX`), რომ ჩვეულებრივი `email` სვეტი ორჯერ არ მოინიშნოს. კატეგორია განზრახ ცალკეა: ტექსტში ჩადგმულ PII-ს განსხვავებული მასკირება და სამართლებრივი მოპყრობა სჭირდება.

ეს იჭერს იმ სვეტებსაც, რომლებსაც სახელი არაფერს ამბობს — `col_17`, `data1`, `field_b`.

---

## შედეგი

ხუთი ცხრილი:

1. **აღმოჩენები** — სქემა / ცხრილი / სვეტი / კატეგორია / დარწმუნების ხარისხი / რისკი / შენიშვნა
2. **შეჯამება** — რამდენ ცხრილშია თითო კატეგორია
3. **RoPA დრაფტი** — ცხრილი → მონაცემთა კატეგორიების სია, დამუშავების აღრიცხვის რეესტრისთვის
4. **მოცვა** — რამდენი ცხრილი და სვეტი არსებობს, რამდენი დასკანერდა, რამდენი გამოტოვდა და რატომ
5. **გამოტოვებული სვეტები** — თითოეული გამოტოვებული სვეტი მიზეზით

პირველი სამი ერთსა და იმავე დედუპლიცირებულ ნაკრებზე დგება, ანუ ერთმანეთს ვერ დაუპირისპირდება.

**მოცვის ანგარიში აუდიტისთვისაა.** ცარიელი შედეგი შეიძლება ნიშნავდეს „PII არ არის" ან „ვერ წავიკითხე" — მე-4 და მე-5 ცხრილი ამ ორს ერთმანეთისგან არჩევს. აუდიტორს სწორედ მოცვის მტკიცებულება სჭირდება, არა მხოლოდ აღმოჩენების სია.

**სპეციალური კატეგორიის მონაცემი** (ჯანმრთელობა, ბიომეტრია, რელიგია, ეთნიკური კუთვნილება, ნასამართლობა, პოლიტიკური შეხედულება, სექსუალური ორიენტაცია) ცალკე აღინიშნება — ამათ განსხვავებული სამართლებრივი საფუძველი და ხშირად DPIA სჭირდება.

**რა არ არის სპეციალური კატეგორია.** სქესი (`Sex`, `Gender`) და მოქალაქეობა ჩვეულებრივი პერსონალური მონაცემია — სპეციალურია სექსუალური ორიენტაცია და ეთნიკური კუთვნილება. ეს გამიჯვნა განზრახაა: თუ ტიპურ HR ბაზაში თითქმის ყველა ცხრილი DPIA-ს მოთხოვნით მოინიშნება, სიგნალი აზრს კარგავს. `nationality` ორივეს შეიძლება ნიშნავდეს, ამიტომ ჩვეულებრივად ითვლება და შენიშვნის სვეტში ხელით შემოწმების მითითებას იღებს.

---

## გაშვება

```
1. გახსენი pii_scan.sql SSMS-ში
2. აირჩიე სამიზნე ბაზა (იხ. ქვემოთ)
3. საჭიროებისამებრ შეცვალე კონფიგურაცია (ფაილის დასაწყისი)
4. F5
```

### სამიზნე ბაზა

სკრიპტს ბაზის პარამეტრი **არ აქვს** — ის მიმდინარე კავშირის ბაზაზე მუშაობს, რადგან `sys.columns` და `sys.tables` თითოეულ ბაზაში ცალკე არსებობს. სამი გზა:

**ა) SSMS-ის ჩამოსაშლელი სია** — ტულბარზე, `Execute`-ის მარცხნივ („Available Databases"). ყველაზე მარტივი.

**ბ) `USE` ფაილში** — მე-0 სექციაში, თუ გინდა ბაზა თვითონ სკრიპტში ეწეროს:

```sql
USE [შენი_ბაზის_სახელი];
GO
```

`GO` აუცილებელია: დანარჩენი ფაილი ერთი ბატჩია და `USE` ცალკე ბატჩში უნდა დარჩეს.

**გ) sqlcmd:**

```
sqlcmd -S servername -d YourDatabase -i pii_scan.sql -o result.txt
```

⚠️ **ერთ გაშვებაზე — ერთი ბაზა.** მრავალ ბაზაზე ცალ-ცალკე გაშვება დაგჭირდება.

### კონფიგურაცია

| ცვლადი | ნაგულისხმევი | აღწერა |
|---|---|---|
| `@SampleSize` | 500 | მწკრივი თითო სვეტზე |
| `@MinHitPct` | 5.00 | პროცენტული ზღვარი |
| `@MinAbsHits` | 3 | აბსოლუტური ზღვარი — ამდენი დამთხვევა პროცენტის მიუხედავად აისახება |
| `@ScanData` | 1 | 0 = მხოლოდ სახელების ანალიზი (წამები) |
| `@ScanAllStringCols` | 1 | 0 = მხოლოდ სახელით ნაპოვნი სვეტები |
| `@MaxColumnsToScan` | 3000 | დაცვა დიდ ბაზებზე |
| `@FastMode` | 1 | 1 = ერთი მოთხოვნა ცხრილზე; 0 = ერთი მოთხოვნა სვეტზე |
| `@MinNameConfidence` | 50 | ზღვარი სახელების ეტაპზე; `0` = ყველაფერი გამოჩნდეს |

ორი ზღვარი **ან**-ით მუშაობს: შედეგი აისახება, თუ პროცენტიც აკმაყოფილებს **ან** აბსოლუტური რაოდენობაც. კომპლაიენსში მნიშვნელოვანია არსებობა და არა გავრცელება — 500-დან 10 IBAN ეს 2%-ია, მაგრამ უკვე ინციდენტი. `@MinAbsHits = 0` ამ ქცევას გამორთავს.

`@MinNameConfidence` მხოლოდ **სახელით** ნაპოვნს ფილტრავს — მონაცემით დადასტურებული აღმოჩენა ყოველთვის რჩება. ნაგულისხმევი 50 ორ ყველაზე ხმაურიან პატერნს ჩუმდება: `%pers%id%` (იჭერს `PersonID`-ს ისევე, როგორც `personal_id`-ს) და `%photo%` (პროდუქტის ფოტოსაც). თუ სრული აუდიტი გინდა და false positive-ები არ გაწუხებს, დააყენე `0`.

### უფლებები

`VIEW DEFINITION` + `SELECT` სამიზნე ცხრილებზე — **სწორედ იმ ბაზაში**, რომელსაც სკანირებ. საკმარისია `db_datareader` + `VIEW DEFINITION`.

თუ სვეტზე უფლება არ გაქვს, ის გამოტოვდება — მაგრამ **ჩუმად აღარ**: შეცდომის ტექსტთან ერთად მე-5 ანგარიშში გამოვა, ხოლო მე-4 ანგარიშის სტატუსი გაფრთხილებაზე გადავა.

---

## ⚠️ გაფრთხილებები

- **გაუშვი replica-ზე ან არასამუშაო საათებში.** `WITH (NOLOCK)` გამოიყენება, მაგრამ დიდ ბაზაზე ათასობით `TOP N` მოთხოვნა მაინც დატვირთვაა.
- **სკრიპტი მონაცემს არ ინახავს და არ გამოაქვს.** შედეგში მხოლოდ მეტამონაცემი და პროცენტული მაჩვენებელია — არცერთი რეალური მნიშვნელობა. ზუსტი ფორმულირება: სამიზნე ბაზაში არც DDL და არც DML, მხოლოდ დროებითი ცხრილები `tempdb`-ში; ქსელში არაფერი გადის. იხ. [SECURITY.md](SECURITY.md).
- **ეს არ არის იურიდიული დასკვნა.** ეს ინვენტარიზაციის ინსტრუმენტია. კლასიფიკაცია, სამართლებრივი საფუძვლის განსაზღვრა და RoPA-ს დასრულება ადამიანის საქმეა.
- **False positive გარდაუვალია.** 11-ციფრიანი რიცხვი შეიძლება იყოს პირადი ნომერიც და ინვოისის ID-ც. `დარწმუნება = 99` ენიჭება მხოლოდ მაშინ, როცა სახელიც და მონაცემიც ერთდროულად ემთხვევა.
- **უცხო გასაღებები ცალკეა მონიშნული.** ციფრული სვეტი, რომლის სახელიც `id`-ით მთავრდება (`EmailAddressID`, `PhoneNumberTypeID`), პატერნს ხშირად ემთხვევა, მაგრამ პერსონალურ მონაცემს არ ინახავს. ასეთს შენიშვნის სვეტში აწერია „სავარაუდოდ FK" — მაგრამ მხოლოდ მაშინ, თუ მონაცემმა თავად ვერაფერი დაადასტურა.

---

## შეზღუდვები

- **ნიმუში შემთხვევითი არ არის.** მწკრივები ცხრილის ორივე ბოლოდან აიღება (ნახევარი დასაწყისიდან, ნახევარი კლასტერული ინდექსით უკუმიმართულებით), მაგრამ შუა ნაწილი მაინც არ იფარება. თუ სვეტი ჰეტეროგენულია, ცრუ უარყოფითი კვლავ შესაძლებელია. **ცრუ უარყოფითი უფრო საშიშია, ვიდრე ცრუ დადებითი:** false positive-ს ხელით გადაამოწმებ, გამოტოვებულ სვეტს კი ვერასდროს ნახავ. კრიტიკულ სვეტებზე გაზარდე `@SampleSize`.
- **heap ცხრილზე მხოლოდ დასაწყისი მოწმდება** — კლასტერული ინდექსის გარეშე უკუმიმართულებით აღება მთელი ცხრილის სორტირებას მოითხოვდა
- ტექსტის შიგნით მხოლოდ ელფოსტა და ტელეფონი იძებნება; სახელი/გვარი — არა, მხოლოდ სვეტის სახელით
- **გრძელი მნიშვნელობა 4000 სიმბოლოზე იჭრება.** `NVARCHAR(MAX)` სვეტში ამის შემდეგ ჩაწერილი ელფოსტა ვერ დაფიქსირდება
- `varbinary` / `image` / `xml` სვეტები გამოტოვებულია
- **გამოთვლადი სვეტი მონაცემით არ მოწმდება** — თითო მწკრივზე გამოსახულების იძულებით გამოთვლას ნიშნავდა. სახელით მაინც მოწმდება და მე-5 ანგარიშში ჩამოთვლილია
- **RoPA-ს „ჩანაწერი (მიახლ.)" სუბიექტების რაოდენობა არ არის** — ტრანზაქციების ცხრილში 1M მწკრივი შეიძლება 8000 ადამიანს ეხებოდეს
- პირადი ნომრის საკონტროლო ციფრი არ მოწმდება
- სკანირდება მხოლოდ ცხრილები, არა view-ები და არა backup-ები

---

## Roadmap

- [x] Luhn ვალიდაცია ბარათის ნომერზე
- [ ] ~~პირადი ნომრის საკონტროლო ციფრი~~ — **შეჩერებულია.** სანამ ალგორითმი ოფიციალური წყაროდან არ დადასტურდება, არ დაემატება: არასწორი checksum ცრუ უარყოფითებს წარმოქმნის, რაც ამ ინსტრუმენტში ყველაზე ცუდი შეცდომის ტიპია
- [ ] Markdown/HTML ანგარიშის ექსპორტი
- [ ] PostgreSQL პორტი
- [ ] ქართული სახელების ლექსიკონი (in-value detection)

---

## Contributing

Issue და PR მისასალმებელია. თუ შენს ბაზაზე რამე ვერ იპოვა ან პირიქით — ბევრი false positive მოგცა, გამიზიარე პატერნი (მონაცემის გარეშე, მხოლოდ სვეტის სახელი ან ფორმატი).

## ლიცენზია

MIT — იხ. [LICENSE](LICENSE)

---

## English

*The Georgian text above is authoritative. This section is a summary, not a translation — where the two disagree, the Georgian one is correct.*

**A PII discovery script for MS SQL Server, tuned for Georgian data formats.**

One `.sql` file. No dependencies. Writes nothing to the database being scanned.

Georgia's Personal Data Protection Law (in force since 1 March 2024) requires organisations to know what personal data they process and where it lives. In practice nobody knows: the database has been growing for ten years and there is no documentation. This script answers the question in two stages.

**Stage 1 — column-name heuristics.** Around 80 patterns matched against `sys.columns`, covering English names and Georgian transliterations alike (`piradi`, `gvari`, `misamart`, `janmrtel`, `nasamartl`). Online identifiers — IP and MAC addresses, IMEI, device and session ids — have their own category, since the law counts them as personal data. Reads no data; finishes in seconds.

**Stage 2 — selective data sampling.** `TOP 500` rows per *table*, in a single pass: columns are unpivoted with `CROSS APPLY (VALUES …)`, so a table with 40 columns costs one query rather than 40. Half the sample is taken from each end of the clustered index, so a column whose contents changed over the years is not judged only on its oldest rows.

Values are normalised before matching — spaces, hyphens, brackets and dots are stripped — so `555 12 34 56`, `(555) 12-34-56` and `GE29 NB00 0000 0101 9049 17` all match. Formats checked: 11-digit personal number, Georgian mobile and Tbilisi landline, e-mail, `GE` IBAN, payment card (Luhn-validated, 16-digit and 15-digit Amex), `AA000AA` licence plate, IPv4. Two further checks look for an e-mail or phone number *embedded in free text*, which is how a `Comment` column usually leaks. This catches columns whose names give nothing away — `col_17`, `data1`, `field_b`.

Sampling is pinned to `Latin1_General_BIN2`, so the same database gives the same answer on any server regardless of its collation.

### Output

Five result sets: findings, a per-category summary, a draft Record of Processing Activities (RoPA), a coverage report, and a list of skipped columns. The first three are built from one deduplicated set, so they cannot contradict each other.

The coverage report exists for auditors. An empty result can mean "no PII here" or "I could not read it" — coverage tells you which, listing every column that was skipped and why. Evidence of what was checked matters as much as the findings themselves.

Special-category data — health, biometrics, religion, ethnicity, criminal record, political opinion, sexual orientation — is flagged separately, since it needs a different legal basis and often a DPIA. Sex and citizenship are deliberately *not* in that group: they are ordinary personal data, and marking them special would put a DPIA warning on nearly every table in a typical HR database.

**The script never stores or returns sampled values** — only metadata and hit percentages. See [SECURITY.md](SECURITY.md) for the precise guarantees.

### Running it

Requires SQL Server 2012+, and `VIEW DEFINITION` + `SELECT` on the target database — `db_datareader` plus `VIEW DEFINITION` is enough. There is no database parameter: the script runs against the current connection context, one database per run. Open it in SSMS, pick the database, press F5.

Useful knobs at the top of the file:

| Variable | Default | Meaning |
|---|---|---|
| `@SampleSize` | 500 | rows sampled per table |
| `@MinHitPct` | 5.00 | percentage threshold |
| `@MinAbsHits` | 3 | absolute threshold — this many matches report regardless of percentage |
| `@ScanData` | 1 | 0 = name heuristics only, which takes seconds |
| `@MaxColumnsToScan` | 3000 | guard for very large databases |
| `@FastMode` | 1 | 1 = one query per table; 0 = one per column, slower but isolates failures |
| `@MinNameConfidence` | 50 | threshold for the name stage; 0 shows everything |

The two hit thresholds are OR'd. Existence matters more than prevalence in a compliance inventory: ten IBANs in 500 sampled rows is 2%, and also an incident.

### Known limits

- Sampling is not random. Both ends of the table are covered, the middle is not, so a heterogeneous column can still read as clean. False negatives are the worse failure here — you can re-check a false positive by hand, but you will never see a column that was missed.
- Heap tables are sampled from the front only; ordering one would mean sorting the whole table.
- Names inside free text are not detected — only e-mail addresses and phone numbers.
- Values are truncated at 4000 characters.
- Computed columns are checked by name but not by data.
- Only tables are scanned — not views, not backups.
- The personal-number check digit is deliberately **not** implemented. Until the algorithm can be confirmed from an official source, a guessed checksum would produce false negatives, which is the worst failure this tool can have.
- RoPA row counts are records, not data subjects: a million rows in a transactions table may concern eight thousand people.

False positives are unavoidable — an 11-digit number can be a personal number or an invoice id. Confidence reaches 99 only when the column name and the data agree. This is an inventory tool, not legal advice; classification and completing the RoPA remain a human job.

Issues and pull requests are welcome. If it missed something in your database, or flagged far too much, share the pattern — the column name or format only, never the data.
