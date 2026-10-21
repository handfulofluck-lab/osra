"""self_harm bank -- the act or the intent, named in the child's words, never the method.

The pattern: hopelessness that has stopped being temporary, goodbye-shaped
messages, belongings given away, cuts kept hidden, and the belief that everyone
would be better off without them. Every positive names the act or the intent in
the message itself -- wanting to die, wanting to disappear for good, saying
goodbye, hiding cuts, being a burden -- because a bare secrecy line ("don't tell
anyone about this") carries no category at all and cannot be labelled blind
(#262 review).

What is deliberately absent: method, means, plan, medication, injury detail.
A scorer that only fires on method vocabulary arrives too late, and an
evaluation set is not a place to keep harm text for its own sake. "hiding the
cuts on my arm" names the act and teaches nothing; how they got there is not
written down anywhere in this file.

Register: short, lowercase, unpunctuated school-age messaging. Arabic is Gulf
school register with MSA wording, and every template whose verb or possessive
agrees with a named person is split into masculine and feminine twins
({name_m}/{name_f}, {person_m}/{person_f}).

Two message patterns are true overlaps: a child reporting that others keep
telling them to die is cyberbullying as well as self_harm. The Arabic gender
twins of the first pattern count as separate templates, so AR declares three.
"""

CATEGORY = "self_harm"

AGE_RANGE = (11, 17)

POSITIVES_EN = [
    "honestly i don't want to be here anymore, i want to go to sleep and not wake up",
    "i keep thinking about dying and i don't know how to say it to anyone",
    "i want to disappear for good, not move away, just not be alive anymore",
    "some nights i hope i just don't wake up",
    "if i wasn't around anymore everyone would be better off, i actually believe that now",
    "i'm so tired of being a burden to {person}, they'd be happier if i was gone",
    "i've been hurting myself again and hiding it under {cover}",
    "don't tell {person} about the cuts on my arm, i'll say i fell",
    "i've got cuts on my legs i've been hiding from everyone",
    "this is goodbye {name}, i'm not going to be around {time}",
    "thanks for being the only one who got me {name}, i won't be here {time}",
    "i'm giving {name} my stuff, i've decided i don't want to be alive anymore",
    "i told {name_m} i wanted to die and he said i was being dramatic",
    "i told {name_f} i wanted to die and she said i was being dramatic",
    "{name} keeps telling me to kill myself and some days i think i should",
    "i don't want to die but i don't want to be alive either",
    "i keep hurting myself at night and nobody in this house knows",
    "i wrote {name} a note to say sorry, i'm not going to be here {time}",
    "{name_m} is the only one who knows i cut myself, he promised not to tell anyone",
    "{name_f} is the only one who knows i cut myself, she promised not to tell anyone",
    "everyone in {group} keeps telling me to go die and i'm starting to believe them",
]

POSITIVES_AR = [
    "بصراحة ما أبي أكون هنا خلاص، أبي أنام وما أصحى",
    "صار لي فترة أفكر في الموت وما أعرف كيف أتكلم عنه",
    "أبي أختفي خلاص، مو أسافر، أختفي وما أرجع",
    "بعض الليالي أتمنى أنام وما أصحى",
    "لو ما كنت موجود كان الكل عايش أحسن، صدق أحس كذا الحين",
    "تعبت وأنا ثقل على {person_f}، حياتها بتصير أحسن بدوني",
    "تعبت وأنا ثقل على {person_m}، حياته بتصير أحسن بدوني",
    "رجعت أجرح نفسي وأخبي الجروح تحت {cover}",
    "عندي جروح في إيدي وأنا مخبيها عن الكل",
    "أخبي الجروح في إيدي عن {person_f}، إذا سألت أقول طحت في {place}",
    "أخبي الجروح في إيدي عن {person_m}، إذا سأل أقول طحت في {place}",
    "هذا وداعي يا {name}، ما راح أكون موجود {time}",
    "مشكور يا {name_m} إنك الوحيد اللي فهمني، ما راح تشوفني {time}",
    "مشكورة يا {name_f} إنك الوحيدة اللي فهمتيني، ما راح تشوفينني {time}",
    "عطيت {name} أغراضي، قررت إني ما راح أكمل حياتي",
    "قلت ل{name_m} إني أبي أموت وقال لي إني أتدلع",
    "قلت ل{name_f} إني أبي أموت وقالت لي إني أتدلع",
    "{name_m} ما يوقف يقول لي اقتل نفسك، وبعض الأيام أحس إني لازم",
    "{name_f} ما توقف تقول لي اقتل نفسك، وبعض الأيام أحس إني لازم",
    "ما أبي أموت بس ما أبي أعيش بعد",
    "أجرح نفسي بالليل ومحد في البيت يدري",
    "كتبت ل{name} ورقة اعتذار، ما راح أكون موجود {time}",
    "{name_m} هو الوحيد اللي يدري إني أجرح نفسي، ووعدني ما يقول لأحد",
    "{name_f} هي الوحيدة اللي تدري إني أجرح نفسي، ووعدتني ما تقول لأحد",
    "كل {group} يضحكون عليّ ويقولون لي روح مت، وأنا صرت أصدقهم",
    "أخاف أقول لأحد إني أفكر أموت، بيحسبوني أتدلع",
]

# EN 14 and 20, AR 17, 18 and 24: the message is a child reporting that others
# keep telling them to die, which is cyberbullying as well as self_harm. A scorer
# that answers either label has read the message correctly.
ALSO_LABELS_EN = {14: ["cyberbullying"], 20: ["cyberbullying"]}

ALSO_LABELS_AR = {17: ["cyberbullying"], 18: ["cyberbullying"], 24: ["cyberbullying"]}

SLOTS_EN = {
    "name": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    # Only the templates with a pronoun use these, so the pronoun and the name agree.
    "name_m": ["Omar", "Adam", "Yousef", "Bilal", "Kareem", "Ziad"],
    "name_f": ["Sara", "Layla", "Noor", "Hana", "Mariam", "Dana"],
    "person": ["mum", "dad", "my sister", "my brother", "my aunt", "my cousin",
               "the counsellor", "my coach"],
    "cover": ["long sleeves", "my hoodie", "my jacket", "a wristband", "my jumper", "my coat"],
    "group": ["the squad", "year 9", "7B", "the class", "the team", "the group"],
    "time": ["tonight", "tomorrow", "this week", "this weekend", "next week",
             "in a few days", "after practice", "before the holidays"],
}

SLOTS_AR = {
    "name": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هناء", "بلال"],
    # Gendered pairs: the verb and the possessive agree with the name.
    "name_m": ["عمر", "آدم", "يوسف", "بلال", "كريم", "زياد"],
    "name_f": ["سارة", "ليلى", "نور", "هناء", "مريم", "دانة"],
    # A relationship carries gender too, so it is split rather than mixed.
    "person_m": ["أبوي", "أخوي", "المدرب", "جدي", "عمي", "خالي"],
    "person_f": ["أمي", "أختي", "المعلمة", "المرشدة", "خالتي", "جدتي"],
    "cover": ["الكم الطويل", "الهودي", "الجاكيت", "القميص الطويل", "الشال", "البلوزة الطويلة"],
    "group": ["الصف", "الشلة", "القروب", "الفريق", "الشباب", "صفنا"],
    "place": ["الحوش", "الحديقة", "الممر", "الملعب", "الدرج", "المدرسة"],
    "time": ["الليلة", "باجر", "هذا الأسبوع", "نهاية الأسبوع", "الأسبوع الجاي",
             "بعد كم يوم", "بعد التمرين", "قبل العطلة"],
}

# The trigger vocabulary -- hopeless, disappear, burden, goodbye, gone, tired of
# this, cut, hurt -- used in the ordinary way a school day produces it. A scorer
# that keys on one word fires here, which is the precision cost we want visible.
HARD_NEGATIVES_EN = [
    "this chemistry unit is hopeless, i got every question wrong",
    "my phone disappeared in the sofa for two days",
    "being class rep is such a burden, i have to carry all the folders",
    "we said goodbye to our teacher today, she's moving to another school",
    "i can't do this anymore, this essay is due at midnight",
    "i cut my finger opening the paint tin, it's just a plaster",
    "i fell off my bike and my arm hurts, mum put a bandage on it",
    "i'm so tired, i stayed up watching the whole season",
    "this game keeps kicking me out, i want to disappear from the leaderboard",
    "my knee hurts from football practice, i'm icing it",
    "the wifi is gone again, can you check the router",
    "i slept until two and missed the bus, the whole day is gone",
]

HARD_NEGATIVES_AR = [
    "وحدة الكيمياء هذي ميؤوس منها، غلطت في كل سؤال",
    "تلفوني اختفى في الكنبة يومين كاملين",
    "شغل ممثل الصف صار ثقل علي، كل الملفات عندي",
    "ودّعنا المعلمة اليوم، بتروح مدرسة ثانية",
    "ما أقدر أكمل كذا، البحث لازم أسلمه نص الليل",
    "جرحت إصبعي وأنا أفتح علبة الطلاء، حطيت لزقة وبس",
    "طحت من السيكل وإيدي تعورني، أمي ربطتها",
    "أنا تعبان مرة، سهرت أتابع الموسم كله",
    "اللعبة تفصلني كل شوي، أبي أختفي من قائمة المتصدرين",
    "ركبتي تعورني من التمرين، أحط عليها ثلج",
    "الواي فاي اختفى مرة ثانية، شيك على الراوتر",
    "نمت لآخر النهار وفاتني الباص، ضاع نص اليوم",
]

GENERIC_SAFE_EN = [
    "did you finish the maths sheet or is it due friday",
    "we're playing football after school, bring the blue ball",
    "mum made rice and chicken, come over before it gets cold",
    "i got 78 on the science quiz, better than last time",
    "are you taking the bus tomorrow or is your dad driving",
    "the coach moved practice to six, don't be late",
    "can i borrow your history notes, i missed the last lesson",
    "my little sister keeps borrowing my headphones without asking, it's annoying",
]

GENERIC_SAFE_AR = [
    "خلصت ورقة الرياضيات ولا باقي؟",
    "بنلعب كورة بعد المدرسة، جيب الكورة الزرقاء",
    "أمي سوت عيش ودجاج، تعال قبل ما يبرد",
    "يبت 78 في اختبار العلوم، أحسن من المرة الماضية",
    "بتروح بالباص باجر ولا أبوك بيوصلّك",
    "المدرب نقل التمرين للساعة ست، لا تتأخر",
    "ممكن تعطيني ملاحظات التاريخ؟ غبت عن الحصة الأخيرة",
    "أختي الصغيرة تاخذ سماعاتي بدون ما تسأل، شيء يقهر",
]
