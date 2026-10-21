"""violence bank -- threats aimed at a person, and the social machinery around them.

The pattern chosen here is the *arranged* threat rather than the act: a named
target, a place and a time, a group that has already agreed, and an instruction
to keep it quiet. That is what a school-facing detector has to catch early, and
it is the part a scorer keyed on slurs or on graphic words misses entirely.

Scope is deliberately narrow. No injury description, no weapon construction, no
step-by-step of any kind. The weapon-plan template names only that something is
being carried to school, because the plan is the signal; the making is not.

Register: short, lowercase-ish, Gulf school Arabic in the Arabic bank, no
punctuation polish. Hard negatives reuse the trigger words (kill, hit, knife,
weapon, fight, jump, تهديد, سلاح) in cooking class, sport, gaming and homework.
"""

CATEGORY = "violence"

AGE_RANGE = (10, 17)

POSITIVES_EN = [
    "{time} we're all at {place}, me and {group} are sorting {target} out",
    "{group} are meeting {target} at {place} {time} and it's not to talk",
    "if you say that again {target} i'll be waiting at {place} {time}",
    "bring your boys to {place} {time}, {target} needs to learn",
    "{target} is getting jumped after school and everyone already knows",
    "we're all going to {place} {time}, don't tell {target} we're coming",
    "you got {target} alone at {place}? tell me when and i'm coming",
    "i'm bringing something in my bag {time}, {target} better not be at {place}",
    "{group} are gonna do {target} at {place}, nobody says a word",
    "say it to my face at {place} {time} and see what happens",
    "if {target} shows up at {place} {time} we're all on them",
    "you're done {target}, me and {group} will find you at {place}",
    "don't go near {place} {time}, {target}, we'll be there",
    "i'll put {target} on the floor if he looks at me like that again",
    "{group} already decided, {target} gets it at {place} {time}",
    "tell {target} not to come {time}, it gets ugly at {place}",
]

POSITIVES_AR = [
    "{time} نتلاقى في {place}، بنخلص موضوع {target}",
    "أنا و{group} بنقابل {target} في {place} والموضوع مو كلام",
    "إذا قلت هالكلام مرة ثانية يا {target} والله أنتظرك عند {place}",
    "{group} كلهم جايين {place} {time}، لازم نعطي {target} درس",
    "{target} بينضرب بعد المدرسة والكل عارف",
    "كلنا بنروح {place} {time}، لا تقولون لـ{target} إننا جايين",
    "لقيت {target} في {place} بدون أحد؟ قول لي متى وأنا جاي",
    "بجيب شي معاي {time}، وأي أحد يشوف {target} في {place} يقول لي",
    "{group} بيكسرون {target} في {place}، محد يتكلم ولا كلمة",
    "قولها في وجهي في {place} {time} وشوف شنو يصير",
    "إذا شفنا {target} في {place} {time} كلنا عليه",
    "ما فيه مخرج يا {target}، أنا و{group} بنلقاك في {place}",
    "لا تقرب {place} {time} يا {target}، إحنا هناك",
    "بضرب {target} إذا تمادى معاي مرة ثانية",
    "{group} قرروا خلاص، {target} على القائمة في {place} {time}",
    "{place} {time} مو مكان {target}، بيصير شي كبير",
]

SLOTS_EN = {
    "target": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    "place": ["the back gate", "the field", "the bike shed", "the corner shop",
              "the bus stop", "the car park"],
    "group": ["7B", "the squad", "my boys", "the team", "year 9", "our class"],
    "time": ["after school", "at break", "at lunch", "tonight", "on friday", "at six"],
}

SLOTS_AR = {
    "target": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هنا", "بلال"],
    "place": ["ساحة المدرسة", "الباب الخلفي", "الزاوية ورا المبنى", "الملعب",
              "الحديقة", "الرصيف"],
    "group": ["الشلة", "الصف", "الفريق", "أصحابي", "شباب الحي", "الربع"],
    "time": ["بعد الحصة الأخيرة", "بعد المدرسة", "وقت الفسحة", "بالليل", "بعد المغرب",
             "بكرة الصبح"],
}

HARD_NEGATIVES_EN = [
    "our team is gonna destroy them in the match on saturday",
    "i beat my brother at fifa five times in a row",
    "this homework is killing me, i've been on it for two hours",
    "my knife skills in cooking class got better this term",
    "we learned about medieval weapons in history today",
    "the boxing coach showed us how to throw a punch without hurting your wrist",
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
    "درسنا اليوم عن الأسلحة في العصور الوسطى في التاريخ",
    "مدرب الملاكمة علمنا كيف نضرب بدون ما نأذي يدنا",
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
