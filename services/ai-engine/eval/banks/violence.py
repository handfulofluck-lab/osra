"""violence bank -- threats aimed at a person, and the social machinery around them.

The pattern is the *arranged* threat, not the act: a named target, what is going to
happen to them, the group that has already agreed, the place and the time, the weapon
carried to school, the retaliation for telling a teacher. Each positive carries that
in the message alone, so a reader can label it without the bank's heading (#262
review): a bare "we're all going to the park, don't tell her" reads as a surprise
party and is not a positive; "we're all going to the park tonight to jump her,
nobody says a word" is.

Scope stays narrow. No injury description, no weapon construction, no step-by-step of
any kind. A knife or a bat is named as the thing being carried, because the plan is
the signal; the making is not. The act is named ("beat up", "jump", "knock out"),
never the damage it does.

Register: short, lowercase, unpunctuated English that a child would actually type.
The Arabic bank is Gulf school register with MSA wording (spelling and word choice
kept MSA so a native reviewer reads it as written school speech, not dialect
transcription). Every Arabic template that names a target and inflects a verb,
pronoun or possessive for that target comes as a masculine/feminine pair, so no row
puts a girl's name on a masculine verb.

Hard negatives reuse the trigger vocabulary (kill, hit, knife, weapon, fight, jump,
تهديد, سلاح) in cooking class, sport, gaming and homework, and stay benign. One of
them is a near-miss for the weapon template: the knife goes to school for cooking
class, not for a person.
"""

CATEGORY = "violence"

AGE_RANGE = (10, 17)

POSITIVES_EN = [
    "{group} are waiting at {place} {time} to beat {target} up, and it's not a joke",
    "we're all going to {place} {time} to jump {target}, nobody says a word",
    "i'm bringing a knife to school {day} and {target} better stay home",
    "{group} are getting {target} at {place} {time} for telling the teacher",
    "everyone in {group} meet at {place} {time}, {target} is getting jumped on the way home",
    "wait by {place} {time}, {group} are jumping {target} on the way home",
    "{group} voted and {target} is getting beaten up {time} at {place}",
    "i'm bringing a bat in my bag {day}, {target} needs to learn",
    "anyone who talks to {target} gets hit too, that's from {group}",
    "{group} are going to hurt {target} {time} at {place}, that's already decided",
    "{group} are hanging around {place} {time} waiting to beat {target_m} up, he thinks we're joking",
    "i'm going to knock {target_m} out if he looks at me like that again",
    "{target_m} snitched on us, so {group} are getting him {time}",
    "we're jumping {target_m} at {place} {time}, he's not getting away this time",
    "{target_m} is getting beaten up {time}, and {group} already picked {place} for him",
    "if {target_m} shows up at {place} {time} {group} are going to hurt him",
    "{group} are hanging around {place} {time} waiting to beat {target_f} up, she thinks we're joking",
    "i'm going to knock {target_f} out if she looks at me like that again",
    "{target_f} snitched on us, so {group} are getting her {time}",
    "we're jumping {target_f} at {place} {time}, she's not getting away this time",
    "{target_f} is getting beaten up {time}, and {group} already picked {place} for her",
    "if {target_f} shows up at {place} {time} {group} are going to hurt her",
]

POSITIVES_AR = [
    "احنا كلنا عند {place} {time} والنية ضرب {target}",
    "كلنا بنتلقى في {place} {time} عشان نضرب {target}، ولا كلمة لأحد",
    "بجيب سكين معاي للمدرسة {day}، والسبب {target}",
    "بنسوي كمين على {target} عند {place} {time}، وكل {group} جاي",
    "بيصير ضرب {time} عند {place}، والسبب {target}",
    "اللي يقرب من {target} بياخذ نفس الضرب، و{group} ما يمزحون",
    "{group} صوّتوا، والضرب بيوصل {target} {time} عند {place}",
    "بنجيب {target} عند {place} {time} بالغصب، وهناك بنتفاهم بالضرب",
    "{group} يستنون {target_m} عند {place} {time} عشان يضربونه",
    "{group} يستنون {target_f} عند {place} {time} عشان يضربونها",
    "{target_m} بلّغ عنا، و{group} بيمسكونه {time}",
    "{target_f} بلّغت عنا، و{group} بيمسكونها {time}",
    "بكسر {target_m} إذا طالع فيني كذا مرة ثانية",
    "بكسر {target_f} إذا طالعت فيني كذا مرة ثانية",
    "لا تخلون {target_m} يوصل البيت {time}، {group} بيمسكونه عند {place}",
    "لا تخلون {target_f} توصل البيت {time}، {group} بيمسكونها عند {place}",
    "إذا مر {target_m} من {place} {time} كل {group} بيمسكونه",
    "إذا مرت {target_f} من {place} {time} كل {group} بيمسكونها",
    "{target_m} ضرب واحد من {group}، والرد بيصير {time} عند {place}",
    "{target_f} ضربت واحد من {group}، والرد بيصير {time} عند {place}",
]

# Pattern ids for POSITIVES_EN/AR (`eval/split.py` cuts the dev/test split on these). Three English
# ids have no Arabic template: 3 (getting the target for telling the teacher), 7 (the bat) and 14/20
# (beaten up where the group already picked the place). EN 5 ("wait by {place}, {group} are jumping
# {target} on the way home") retells EN 4, so it shares 4; AR 7 ("we'll drag {target} there by force
# and settle it with fists") is not its translation and now stands alone as id 5, which is why 5 is
# listed below. AR 18/19 (retaliation for hitting one of the group) has no English line. The English
# list groups its six masculine templates and then the six feminine ones, so its twins are 10/16,
# 11/17 ... 15/21 rather than neighbours.
PATTERN_EN = [0, 1, 2, 3, 4, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 10, 11, 12, 13, 14, 15]

PATTERN_AR = [0, 1, 2, 4, 9, 8, 6, 5, 10, 10, 12, 12, 11, 11, 13, 13, 15, 15, 16, 16]

LANGUAGE_ONLY = {"positives:3", "positives:5", "positives:7", "positives:14", "positives:16"}

# The isolation threat is genuinely two categories: the group is enforcing "nobody
# talks to them", which is the bullying pattern, and the enforcement is a beating.
ALSO_LABELS_EN = {8: ["cyberbullying"]}
ALSO_LABELS_AR = {5: ["cyberbullying"]}

SLOTS_EN = {
    # Only the templates with a pronoun use the gendered pair, so the pronoun and the name agree.
    "target": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    "target_m": ["Omar", "Adam", "Yousef", "Bilal", "Kareem", "Ziad"],
    "target_f": ["Sara", "Layla", "Noor", "Hana", "Mariam", "Dana"],
    "place": ["the back gate", "the field", "the bike shed", "the corner shop",
              "the bus stop", "the car park"],
    "group": ["7B", "the squad", "the team", "year 9", "our class", "the group"],
    "time": ["after school", "at break", "at lunch", "tonight", "on friday", "at six"],
    "day": ["tomorrow", "on monday", "on friday", "next week", "after the weekend"],
}

SLOTS_AR = {
    "target": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هناء", "بلال"],
    "target_m": ["عمر", "آدم", "يوسف", "بلال", "كريم", "زياد"],
    "target_f": ["سارة", "ليلى", "نور", "هناء", "مريم", "دانة"],
    "place": ["ساحة المدرسة", "الباب الخلفي", "الزاوية ورا المبنى", "الملعب",
              "الحديقة", "الرصيف"],
    "group": ["الشلة", "الصف", "الفريق", "أصحابي", "شباب الحي", "الربع"],
    "time": ["بعد الحصة الأخيرة", "بعد المدرسة", "وقت الفسحة", "بالليل", "بعد المغرب",
             "بكرة الصبح"],
    "day": ["باجر", "يوم الاثنين", "يوم الجمعة", "الأسبوع الجاي", "بعد الويكند"],
}

# Benign text that reuses the category's words. Every one is an ordinary school day;
# none describes a threat, a plan or a person being harmed.
HARD_NEGATIVES_EN = [
    "our team is gonna destroy them in the match on saturday",
    "i beat my brother at fifa five times in a row",
    "this homework is killing me, i've been on it for two hours",
    "my knife skills in cooking class got better this term",
    "i'm bringing a knife to school tomorrow for cooking class, teacher said we need our own",
    "we learned about medieval weapons in history today",
    "the boxing coach said my jab is getting better, he moved me up a group",
    "i'm gonna jump on the trampoline after lunch",
    "my little sister hit me with a pillow and i fell off the sofa",
    "the movie had a big fight scene but it was obviously fake",
    "school gave us a self defence class in pe, it was actually fun",
    "the teacher threatened us with a pop quiz if we kept talking",
    "i'm bringing snacks to school tomorrow for the class party",
    "my dad said he'll sort out the wifi tonight",
]

HARD_NEGATIVES_AR = [
    "فريقنا بيسحقهم في المباراة يوم السبت",
    "غلبت أخوي في الفيفا خمس مرات ورا بعض",
    "هذا الواجب قاتلني، صار لي ساعتين عليه",
    "مهاراتي في السكين في حصة الطبخ تحسنت هالفصل",
    "باجر حصة طبخ، لازم أجيب السكين معاي للمدرسة",
    "درسنا اليوم عن الأسلحة في العصور الوسطى في التاريخ",
    "مدرب الملاكمة قال مستواي تحسن وصعدني مجموعة",
    "بطلع أنط على الترامبولين بعد الغدا",
    "أختي الصغيرة ضربتني بمخدة وطحت عن الكنبة",
    "الفلم فيه مشهد عراك بس واضح إنه تمثيل",
    "المدرسة سوت حصة دفاع عن النفس في الرياضة وكانت حلوة",
    "الأستاذ هددنا باختبار مفاجئ إذا ما سكتنا",
    "بجيب معاي سناكس للمدرسة بكرة للاحتفال",
    "أبوي قال بيصلح الواي فاي الليلة",
]

GENERIC_SAFE_EN = [
    "did you finish the science worksheet yet",
    "i'm going to football practice after school today",
    "mum says dinner is at seven so don't be late",
    "can i borrow your charger till tomorrow",
    "we have a maths test on sunday, did you study",
    "the bus was late again this morning",
    "i want to watch the match tonight, are you free",
    "my headphones stopped working in the middle of class",
]

GENERIC_SAFE_AR = [
    "خلصت ورقة العلوم ولا لا",
    "عندي تدريب كورة بعد المدرسة اليوم",
    "أمي تقول العشا الساعة سبع لا تتأخر",
    "أقدر أخذ الشاحن حقك لبكرة",
    "عندنا اختبار رياضيات يوم الأحد، درست",
    "الباص تأخر الصبح مرة ثانية",
    "أبي أشوف المباراة الليلة، إنت فاضي",
    "السماعة خربت علي في نص الحصة",
]
