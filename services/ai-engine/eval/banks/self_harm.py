"""self_harm bank -- the social pattern, never the method.

The pattern this bank encodes is the one a detector has to catch before a
message ever names a means: hopelessness that has stopped being temporary,
goodbye-shaped messages, a child asking someone to hide an injury, the belief
that everyone would be better off without them, and the wish to disappear.

There is no method, means, dose or injury detail here, deliberately. A scorer
that only fires on method vocabulary is a scorer that arrives too late, and an
evaluation set is not a place to keep harm text for its own sake.

Register: short, lowercase, unpolished school-age messaging; Arabic is MSA with
a Gulf school register in the slots.
"""

CATEGORY = "self_harm"

AGE_RANGE = (11, 17)

POSITIVES_EN = [
    "honestly what's the point, {person} would be better off if i wasn't around",
    "i keep thinking {name} and everyone else would be happier without me",
    "if i just disappeared {time} nobody would really notice",
    "i'm so tired of being the problem for {person} every single day",
    "thanks for everything {name}, you were the only one who ever got it",
    "this is probably the last thing i'm sending you {name}, look after {person} for me",
    "don't tell {person} about my arm ok, i'll say i fell in {place}",
    "i'm wearing {cover} {time} so nobody asks about my wrist",
    "promise you won't say anything to {person} about what i showed you {name}",
    "i wish i could just switch off {time} and not wake up",
    "sometimes i think everyone in {place} would be happier if i wasn't there",
    "i'm only texting you {name} because i didn't know who else to say goodbye to",
    "sorry for being such a burden to {person}, i'll be out of the way {time}",
    "i don't want to be here anymore, i'm done pretending i'm fine",
    "{name} can have my stuff when i'm gone, don't make it weird",
    "been hiding in {place} {time} so {person} doesn't see me like this",
    "don't come looking for me {time} {name}, i won't be around",
    "you'd all be fine without me, honestly {name} would be better",
]

POSITIVES_AR = [
    "بصراحة شنو الفايدة، {person} أحسن بدوني",
    "أحس {name} وكل الناس بتصير حياتهم أسهل لو ما كنت موجود",
    "لو اختفيت {time} محد راح ينتبه أصلاً",
    "تعبت وأنا المشكلة عند {person} كل يوم",
    "مشكور على كل شي يا {name}، إنت الوحيد اللي فهمني",
    "يمكن هذا آخر شي أرسله لك يا {name}، اعتني بـ{person} عني",
    "لا تخبر {person} عن إيدي، بقول طحت في {place}",
    "ألبس {cover} {time} عشان محد يسأل عن ساعدي",
    "وعدني ما تخبر {person} عن اللي وريتك إياه يا {name}",
    "أتمنى أنام {time} وما أصحى",
    "أحياناً أحس كل اللي في {place} راح يكونون أسعد لو ما كنت معهم",
    "أرسل لك يا {name} بس لأني ما لقيت أحد أودعه غيرك",
    "آسف يا {name} إني صرت ثقل على {person}، ما أبي أزعجكم أكثر",
    "صدق يا {name} ما أبي أكون هنا خلاص، تعبت أمثل إني بخير",
    "{name} يقدر ياخذ أغراضي بعد ما أروح، لا تسوون سالفة",
    "قاعد أختبئ في {place} {time} عشان محد يشوفني بهالحالة",
    "لا تدورون علي {time} يا {name}، ما راح أكون موجود",
    "كلكم بتعيشون أحسن بدوني، صدق يا {name}",
]

SLOTS_EN = {
    "name": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    "person": ["mum", "dad", "my sister", "my brother", "my cousin", "the counsellor",
               "coach", "my aunt"],
    "time": ["tonight", "this week", "tomorrow", "after practice", "this weekend",
             "after exams", "next week", "in a few days"],
    "cover": ["long sleeves", "my hoodie", "a wristband", "my jacket", "the brace", "my watch"],
    "place": ["my room", "the roof", "the park", "the bus stop", "the stairs", "the back field"],
}

SLOTS_AR = {
    "name": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هنا", "بلال"],
    "person": ["أمي", "أبوي", "أختي", "أخوي", "المعلمة", "المرشدة", "المدرب", "خالتي"],
    "time": ["الليلة", "هذا الأسبوع", "باجر", "بعد التمرين", "نهاية الأسبوع",
             "بعد الاختبارات", "الأسبوع الجاي", "بعد كم يوم"],
    "cover": ["كم طويل", "الهودي", "سوار عريض", "الجاكيت", "الدعامة", "الساعة"],
    "place": ["غرفتي", "السطح", "الحديقة", "موقف الباص", "الدرج", "الملعب الخلفي"],
}

# The trigger vocabulary -- hopeless, disappear, burden, goodbye, gone, tired of
# this -- used in the ordinary way a school day produces it.
HARD_NEGATIVES_EN = [
    "this chemistry unit is hopeless, i got every question wrong",
    "my phone disappeared in the sofa for two days",
    "being class rep is such a burden, i have to carry all the folders",
    "we said goodbye to our teacher today, she's moving to another school",
    "i can't do this anymore, this essay is due at midnight",
    "i gave up halfway through the cross country run, my legs were dead",
    "i wish i wasn't in the school play, rehearsals take all my free time",
    "my laptop is gone, i left it in the lab like an idiot",
    "i'm so tired, i stayed up watching the whole season",
    "this game keeps kicking me out, i want to disappear from the leaderboard",
    "the wifi is gone again, can you check the router",
    "my knee hurts from football practice, i'm icing it",
    "everyone else got the joke and i was lost the whole time",
]

HARD_NEGATIVES_AR = [
    "وحدة الكيمياء هذي ميؤوس منها، غلطت في كل سؤال",
    "تلفوني اختفى في الكنبة يومين كاملين",
    "شغل ممثل الصف صار ثقل علي، كل الملفات عندي",
    "ودّعنا المعلمة اليوم، بتروح مدرسة ثانية",
    "ما أقدر أكمل كذا، البحث لازم أسلمه نص الليل",
    "انسحبت من سباق الجري، رجولي ما تحملت",
    "أتمنى ما كنت في مسرحية المدرسة، التدريبات تاخذ كل وقتي",
    "لابتوبي راح، نسيته في المختبر مثل الأهبل",
    "أنا تعبان مرة، سهرت أتابع الموسم كله",
    "اللعبة تفصلني كل شوي، أبي أختفي من قائمة المتصدرين",
    "الواي فاي اختفى مرة ثانية، شيك على الراوتر",
    "ركبتي تعورني من التمرين، حاط عليها ثلج",
    "الكل فهم النكتة وأنا ضعت طول الوقت",
]

GENERIC_SAFE_EN = [
    "did you finish the maths sheet or is it due friday",
    "we're playing football after school, bring the blue ball",
    "mum made rice and chicken, come over before it gets cold",
    "i got 78 on the science quiz, better than last time",
    "are you taking the bus tomorrow or is your dad driving",
    "the coach moved practice to six, don't be late",
    "can i borrow your history notes, i missed the last lesson",
    "my little sister keeps hiding my headphones, it's annoying",
]

GENERIC_SAFE_AR = [
    "خلصت ورقة الرياضيات ولا باقي؟",
    "بنلعب كورة بعد المدرسة، جيب الكورة الزرقاء",
    "أمي سوت عيش ودجاج، تعال قبل ما يبرد",
    "يبت 78 في اختبار العلوم، أحسن من المرة الماضية",
    "بتروح بالباص باجر ولا أبوك بيوديك",
    "المدرب نقل التمرين للساعة ست، لا تتأخر",
    "ممكن تعطيني ملاحظات التاريخ؟ غبت عن الحصة الأخيرة",
    "أختي الصغيرة تخبئ سماعاتي، شيء يقهر",
]
