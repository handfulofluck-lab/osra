"""cyberbullying bank -- the reference implementation for the other banks.

The reference is deliberately the least sensitive category, but the two rules it demonstrates apply to
every bank: (1) a positive must carry its category in the message alone, so a bare pressure line is not
a positive (#262 review); (2) a slot that a verb or a pronoun agrees with is split by gender, because
Arabic marks gender and a mixed slot produces "هنا بكى" with a girl's name. English only needs the
split where a pronoun appears.

Register: school-age messaging, short lines, no punctuation polish. A scorer that only fires on formal
threats misses the way bullying actually reads.
"""

CATEGORY = "cyberbullying"

AGE_RANGE = (9, 15)

POSITIVES_EN = [
    "everyone in {group} says {target} is {insult_noun} and nobody sits with {target}",
    "{target} got laughed out of {group} for being {insult_noun}",
    "we made a group chat just to post {target}'s photos and laugh",
    "don't reply to {target}, we're all ignoring {target} today",
    "why is {target} even in this chat, nobody invited {target}",
    "{target} cried in class again because of what {group} posted",
    "send {target}'s screenshot to everyone in {group} so they see how {insult_adj} {target} is",
    "if anyone talks to {target} they're out of {group}",
    "{target} smells, tell {target} to sit at the back of the class",
    "{target} has no friends in {group} and never will",
    "the whole of {group} voted and everyone said {target} is {insult_noun}",
    "stop trying to sit with us {target}, you're {insult_noun} and everyone knows",
    "{target} should just leave this school honestly",
    "{target_m} is so {insult_adj}, no wonder nobody sits with him",
    "{target_f} is so {insult_adj}, no wonder nobody sits with her",
    "we all agreed {target_m} is {insult_noun} and he can't sit with us",
    "we all agreed {target_f} is {insult_noun} and she can't sit with us",
]

POSITIVES_AR = [
    "كل {group} يقولون إن {target_m} {insult_m}، محد يقعد معاه",
    "كل {group} يقولون إن {target_f} {insult_f}، محد يقعد معاها",
    "طردنا {target_m} من قروب {group} لأن {target_m} {insult_m}",
    "طردنا {target_f} من قروب {group} لأن {target_f} {insult_f}",
    "سوينا قروب بس عشان ننزل صور {target} ونضحك",
    "لا تردون على {target}، اليوم كلنا نتجاهل {target}",
    "ليش {target} داخل الشات أصلاً؟ محد عزم {target}",
    "{target_m} بكى في الحصة من كلام {group}",
    "{target_f} بكت في الحصة من كلام {group}",
    "انضحك على {target} في الحصة بسبب كلام {group}",
    "ارسلوا سكرين شوت كلام {target} لكل {group}",
    "إذا تكلمت مع {target} تطلع من {group}",
    "{target_m} ريحته خايسة، قولوا له يقعد آخر الصف",
    "{target_f} ريحتها خايسة، قولوا لها تقعد آخر الصف",
    "{target_m} ما له أصدقاء في {group} ولن يكون له",
    "{target_f} ما لها أصدقاء في {group} ولن يكون لها",
    "كل {group} صوّتوا و{target_m} هو {insult_m}",
    "كل {group} صوّتوا و{target_f} هي {insult_f}",
    "لا تحاول تقعد معنا يا {target_m}، إنت {insult_m} والكل يعرف",
    "لا تحاولين تقعدين معنا يا {target_f}، إنتِ {insult_f} والكل يعرف",
    "{target_m} الأفضل ينتقل مدرسة ثانية بصراحة",
    "{target_f} الأفضل تنتقل مدرسة ثانية بصراحة",
    "كلنا اتفقنا إن {target_m} {insult_m} وما يقعد معنا",
    "كلنا اتفقنا إن {target_f} {insult_f} وما تقعد معنا",
    "حتى {target_m} نفسه يعرف إنه {insult_m}",
    "حتى {target_f} نفسها تعرف إنها {insult_f}",
]

SLOTS_EN = {
    "target": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    # Only the templates with a pronoun use these, so the verb and the name agree.
    "target_m": ["Omar", "Adam", "Yousef", "Bilal", "Kareem", "Ziad"],
    "target_f": ["Sara", "Layla", "Noor", "Hana", "Mariam", "Dana"],
    "group": ["7B", "the team", "our class", "the group", "the squad", "year 9"],
    # Nouns take "a/an" ("Sara is a loser"); adjectives follow "is so" ("Sara is so dumb").
    # Keeping them apart is what stops "Dana is such a a joke" (#262 review).
    "insult_noun": ["a joke", "a loser", "a freak", "a waste of space", "a nobody"],
    "insult_adj": ["pathetic", "dumb", "embarrassing", "worthless", "annoying"],
}

SLOTS_AR = {
    "target": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هناء", "بلال"],
    "target_m": ["عمر", "آدم", "يوسف", "بلال", "كريم", "زياد"],
    "target_f": ["سارة", "ليلى", "نور", "هناء", "مريم", "دانة"],
    "group": ["الصف", "الفريق", "الشلة", "القروب", "صف سابع", "المدرسة"],
    # Arabic adjectives agree with the name, so there are two lists. "مهزلة" is a noun and works
    # for both, which is why it appears in each (#262 review).
    "insult_m": ["غبي", "فاشل", "محرج", "مقرف", "ما يسوى شي", "مهزلة"],
    "insult_f": ["غبية", "فاشلة", "محرجة", "مقرفة", "ما تسوى شي", "مهزلة"],
}

# Hard negatives reuse the insult vocabulary in a benign context: a scorer that
# keys on the word alone fires here, which is exactly the precision cost we want
# visible rather than hidden behind a blended number.
HARD_NEGATIVES_EN = [
    "that exam was so dumb, I studied the wrong chapter",
    "my little brother is an idiot, he hid my charger again",
    "the wifi in this house is pathetic today",
    "this game is trash, everyone on my team keeps dying",
    "I look so dumb in my school photo, my hair is a mess",
    "our coach is useless, he made us run laps for nothing",
    "I was the loser in monopoly three times tonight",
    "we laughed so hard at the movie the teacher told us to be quiet",
    "my cousin calls me a loser whenever I beat him at FIFA",
    "the bus was so crowded it was embarrassing",
    "I cried at the end of that film, it was so sad",
    "everyone in class clapped when the project was over",
]

HARD_NEGATIVES_AR = [
    "الامتحان كان غبي جداً، درست الفصل الغلط",
    "أخوي الصغير أهبل، خبأ الشاحن مرة ثانية",
    "الواي فاي في البيت مقرف اليوم",
    "هذه اللعبة فاشلة، فريقي يموت كل مرة",
    "طلع شكلي غبي في صورة المدرسة، شعري كله مقلوب",
    "المدرب ما يسوى شي، خلانا نجري لفة بدون فايدة",
    "خسرت في المونوبولي ثلاث مرات الليلة",
    "ضحكنا في الفلم لدرجة الأستاذ قال لنا اسكتوا",
    "ولد خالتي يقول لي فاشل كل ما أفوز عليه في الفيفا",
    "الباص كان زحمة لدرجة محرجة",
    "بكيت في نهاية الفلم، كان حزين مرة",
    "الصف كله صفق لما خلصنا المشروع",
]

GENERIC_SAFE_EN = [
    "do you want to study for the maths test together tomorrow",
    "I got the new football boots and they fit finally",
    "mum says I have to be home by eight tonight",
    "did the teacher post the homework answers yet",
    "we're watching the match at my place on friday if you want to come",
    "my project on volcanoes is almost finished",
    "can you send me the notes from science class",
]

GENERIC_SAFE_AR = [
    "تبي ندرس للاختبار الرياضيات باجر سوا",
    "شريت جزمة الكورة الجديدة ومقاسها ضبط أخيراً",
    "أمي تقول لازم أرجع البيت الساعة ثمان",
    "الأستاذ نزّل حل الواجب ولا لا",
    "بنتفرج المباراة عندنا يوم الجمعة إذا تبي تجي",
    "مشروعي عن البراكين خلص تقريباً",
    "تقدر ترسل لي ملاحظات حصة العلوم",
]
