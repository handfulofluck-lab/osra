"""substance_use bank -- offers, peer pressure, concealment, and the dealer as a character.

Every positive names the substance in the line itself -- vape, weed, a joint, a pill, beer, being
high, buying from a guy -- and the pressure or the secrecy is the frame around that name, not a
substitute for it. The old shape, "delete this chat before your mum goes through your phone", is no
longer a positive: it carries no category, so a careful reader cannot label it (#262 review).
Nothing here states a dose, a price, a way to obtain it, or what it feels like in a way that could
be read as advice. The dealer stays a character -- someone who sells, who is owed, who calls --
never a route.

Two templates are true overlaps and carry both labels: 5 is a debt threat (violence) and 18/19 is
ostracism after being caught (cyberbullying).

Gender: templates whose verb, pronoun or possessive agrees with the target come in
`{target_m}`/`{target_f}` pairs (14/15, 16/17, 18/19), because Arabic marks gender and a mixed
slot produces "هناء يجيب". `{target}` is used only in vocatives and possessives with no agreement.

Register: Gulf school register with MSA wording. English is short, lowercase-ish, unpunctuated.
Arabic is Gulf colloquial (بعدني، محد، عشان، بيوقف لك) carrying MSA vocabulary for the substances
(الحشيش، الحبوب، البيرة). "الشايب" is not used for the older guy -- it reads as "old man" rather
than the peer-adjacent adult this pattern needs -- so "واحد كبير" stands in its place.
"""

CATEGORY = "substance_use"

AGE_RANGE = (12, 17)

POSITIVES_EN = [
    "we're vaping in the toilets at break, just stand at the door and watch for us",
    "everyone in {group} hits the vape at lunch, why are you still saying no, {target}",
    "just take a pull of this joint and pass it back, nobody's going to tell on you",
    "my mum thinks i'm at {target}'s house, don't say anything about the weed",
    "the older guy who sells us weed says we owe him now and he knows where we live",
    "if you don't bring the money for the pills the older guy is going to wait for you after school",
    "i'm so high in {class} right now and sir thinks i'm just tired",
    "sat at the back in {class} so nobody sees my eyes, the weed was strong",
    "don't tell your mum about the beer at {target}'s, she'll ring mine",
    "delete this chat before your mum goes through your phone, there's stuff about the vape in it",
    "{target} why are you being so weird about the joint, it's not even a big deal",
    "just keep the pills at mine, my mum never comes in my room",
    "i told my mum i stopped vaping but i still do it with {group} at break",
    "you can't sit with {group} if you won't even take a hit of the vape",
    "the guy we buy weed from keeps messaging {target_m} to bring more people from {group}",
    "the guy we buy weed from keeps messaging {target_f} to bring more people from {group}",
    "we were drinking beer in the park and {target_f} got sick, don't tell anyone",
    "we were drinking beer in the park and {target_m} got sick, don't tell anyone",
    "{target_m} got caught with a vape in {class} and now nobody in {group} will talk to him",
    "{target_f} got caught with a vape in {class} and now nobody in {group} will talk to her",
]

POSITIVES_AR = [
    "نسحب فيب في الحمامات وقت الفسحة، بس قف على الباب وراقب لنا",
    "كل {group} يسحبون فيب وقت الغدا، ليش إنت بعدك تقول لا يا {target_m}",
    "كل {group} يسحبون فيب وقت الغدا، ليش إنتِ بعدك تقولين لا يا {target_f}",
    "خذ سحبة من سجارة الحشيش ومررها، محد بيقول شي",
    "أمي تحسبني عند {target}، لا تقول لها شي عن الحشيش",
    "واحد كبير يبيع لنا الحشيش يقول إحنا مدينين له ويعرف وين نسكن",
    "إذا ما جبت فلوس الحبوب، الواحد الكبير بيوقف لك بعد المدرسة",
    "أنا طاير من الحشيش في حصة {class} والأستاذ يحسبني تعبان",
    "قاعد آخر الصف عشان محد يشوف عيوني، الحشيش كان قوي",
    "لا تقول لأمك عن البيرة اللي شربناها عند {target}، بتتصل بأمي",
    "امسح هذا الشات قبل أمك تفتش جوالك، فيه كلام عن الفيب",
    "ليش تسوي نفسك غريب عشان سجارة حشيش، الموضوع عادي يا {target_m}",
    "ليش تسوين نفسك غريبة عشان سجارة حشيش، الموضوع عادي يا {target_f}",
    "خل الحبوب عندي، أمي ما تدخل غرفتي أبد",
    "قلت لأمي إني وقفت الفيب، بس بعدني أسحب مع {group} وقت الفسحة",
    "ما تقدر تجلس مع {group} إذا ما تسحب فيب معانا",
    "اللي يبيع لنا الحشيش ما يوقف عن مراسلة {target_m} عشان يجيب ناس من {group}",
    "اللي يبيع لنا الحشيش ما يوقف عن مراسلة {target_f} عشان تجيب ناس من {group}",
    "شربنا بيرة في الحديقة و{target_f} صارت تعبانة مرة، لا تقولون لأحد",
    "شربنا بيرة في الحديقة و{target_m} صار تعبان مرة، لا تقولون لأحد",
    "{target_m} انمسك في {class} ومعه فيب، والحين محد في {group} يكلمه",
    "{target_f} انمسكت في {class} ومعاها فيب، والحين محد في {group} يكلمها",
]

# Pattern ids for POSITIVES_EN/AR (`eval/split.py` cuts the dev/test split on these). AR inserts a
# gender twin wherever the verb agrees with the target (AR 1/2, 11/12), and the English m/f pairs
# 14/15, 16/17 and 18/19 share one id each. No id is language-only.
PATTERN_EN = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 14, 15, 15, 16, 16]

PATTERN_AR = [0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 14, 15, 15, 16, 16]

SLOTS_EN = {
    "target": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    # Only the templates with a pronoun use these, so the pronoun and the name agree.
    "target_m": ["Omar", "Adam", "Yousef", "Bilal", "Kareem", "Ziad"],
    "target_f": ["Sara", "Layla", "Noor", "Hana", "Mariam", "Dana"],
    "group": ["the squad", "year 9", "7B", "the team", "our class", "the year group"],
    "class": ["maths", "science", "PE", "art", "history", "geography"],
}

SLOTS_AR = {
    "target": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هناء", "بلال"],
    "target_m": ["عمر", "آدم", "يوسف", "بلال", "كريم", "زياد"],
    "target_f": ["سارة", "ليلى", "نور", "هناء", "مريم", "دانة"],
    "group": ["الشلة", "الصف", "الفريق", "القروب", "الشباب", "صف تاسع"],
    "class": ["الرياضيات", "العلوم", "البدنية", "الفن", "التاريخ", "الجغرافيا"],
}

# Hard negatives reuse the substance vocabulary in a benign context: a scorer that keys on the
# word alone fires here, which is the precision cost we want visible rather than hidden behind a
# blended number. None of them is a real positive.
HARD_NEGATIVES_EN = [
    "my high score on the football game finally beat my brother's",
    "the barbecue smoke made my eyes water all evening",
    "the team was on a high after we won the final",
    "the joint on my desk chair snapped so i'm doing homework on the floor",
    "we had a lesson about vaping in health class and the poster was actually interesting",
    "my uncle quit smoking last year and he's really proud of it",
    "my dad is a car dealer, so he's out late most weekends",
    "the allergy pill my doctor gave me makes me sleepy so i take it before bed",
    "the group chat for the school trip is going mad, 200 messages already",
    "my little sister keeps hiding my headphones in her room",
    "i told mum about breaking the plate and she wasn't even angry",
    "the teacher said the smoke alarm test is on friday so don't panic",
    "our class watched a film about a doctor who works nights",
    "the fizzy drink went everywhere when i opened it, my shirt is soaked",
]

HARD_NEGATIVES_AR = [
    "أعلى نتيجة في اللعبة سجلتها أنا مو أخوي",
    "دخان الشوي دخل عيوني طول الليل",
    "أبوي كان يدخن زمان وتركها من سنتين والحين صحته أحسن",
    "حصة الصحة اليوم كانت عن أضرار التدخين والأستاذ جاب صور",
    "أخوي الكبير تاجر سيارات ويشتغل كل الويكند",
    "حبوب الحساسية من الصيدلية تخلي الواحد ينام بدري",
    "المفصل حق ركبتي يعورني في البرد، الدكتور قال عادي",
    "مسحوق الغسيل خلص، أمي طلبت مني أجيب واحد جديد",
    "النادي ريحته دخان من الشوي حق العشاء",
    "المدرسة أرسلت رسالة لأهلنا عن الفيب وحضرنا الاجتماع",
    "أستاذ الكيمياء شرح لنا الفرق بين الدخان والبخار في التجربة",
    "أختي الصغيرة تخبي سماعاتي في غرفتها كل يوم",
]

# Pattern ids for HARD_NEGATIVES_EN/AR. EN 2, 8 and 10-13 have no Arabic line (team on a high, the
# school-trip group chat, the broken plate, the smoke-alarm test, the film about a doctor, the fizzy
# drink), and AR 7-10 have none in English (laundry powder, the club smelling of smoke, the school's
# vaping letter, smoke against vapour). The aligned middle maps EN 3 <-> AR 6, EN 4 <-> AR 3,
# EN 5 <-> AR 2, EN 6 <-> AR 4 and EN 7 <-> AR 5.
PATTERN_HARD_NEG_EN = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]

PATTERN_HARD_NEG_AR = [0, 1, 5, 4, 6, 7, 3, 14, 15, 16, 17, 9]

GENERIC_SAFE_EN = [
    "did you finish the history worksheet or should we do it together",
    "my mum's making rice and chicken tonight if you want to stay",
    "the football match starts at seven so come over before that",
    "I left my science book in class, can you bring it tomorrow",
    "we have a spelling test on sunday so I'm revising tonight",
    "the new kid in our class is really good at basketball",
    "my dad's picking me up after practice, see you at the gate",
]

GENERIC_SAFE_AR = [
    "اليوم عندنا تدريب كرة بعد المدرسة، تبي تجي",
    "أمي تسأل إذا تبغى تتعشى عندنا اليوم",
    "نسيت كتاب العلوم في الصف، تقدر تجيبه باجر",
    "المباراة تبدأ الساعة سبع، خلص واجبك قبل",
    "شفت الفيديو حق مشروع الأحياء؟ حلو مرة",
    "أبوي بيوصلني المدرسة باجر الصبح",
    "عندنا اختبار إملاء يوم الأحد، لازم نراجع",
]

# Pattern ids for GENERIC_SAFE_EN/AR. These two lists are *not* translations in the same order:
# EN 1 <-> AR 1, EN 2 <-> AR 3, EN 3 <-> AR 2, EN 4 <-> AR 6, EN 6 <-> AR 5. EN 0 and 5 (history
# worksheet, the new kid at basketball) and AR 0 and 4 (football training, the biology video) have no
# counterpart, so they keep ids outside the shared numbering.
PATTERN_SAFE_EN = [0, 1, 2, 3, 4, 5, 6]

PATTERN_SAFE_AR = [7, 1, 3, 2, 8, 6, 4]

LANGUAGE_ONLY = {"hard_negatives:2", "hard_negatives:8", "hard_negatives:10", "hard_negatives:11",
                 "hard_negatives:12", "hard_negatives:13", "hard_negatives:14", "hard_negatives:15",
                 "hard_negatives:16", "hard_negatives:17", "generic_safe:0", "generic_safe:5",
                 "generic_safe:7", "generic_safe:8"}

# 5 is a debt threat as well as substance pressure; 18/19 ostracise the child who was caught.
ALSO_LABELS_EN = {5: ["violence"], 18: ["cyberbullying"], 19: ["cyberbullying"]}

ALSO_LABELS_AR = {5: ["violence"], 18: ["cyberbullying"], 19: ["cyberbullying"]}
