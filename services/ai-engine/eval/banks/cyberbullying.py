"""cyberbullying bank -- the reference implementation for the other banks.

The reference is deliberately the least sensitive category: it shows the shape
(templates with slots, real-sounding teen register, hard negatives that reuse
the trigger vocabulary benignly) without touching self-harm or grooming, where
the content rule in `eval/banks/__init__.py` matters most.

Register: school-age messaging, short lines, no punctuation polish. A scorer
that only fires on formal threats misses the way bullying actually reads.
"""

CATEGORY = "cyberbullying"

AGE_RANGE = (9, 15)

POSITIVES_EN = [
    "everyone in {group} thinks you're {insult}, {target}",
    "{target} is such a {insult}, no wonder nobody sits with them",
    "did you see what {target} wore today, so {insult}",
    "we made a group chat just to laugh at {target}",
    "nobody in {group} actually likes you {target}",
    "don't reply to {target}, we're all ignoring them today",
    "why are you even in this chat {target}, nobody invited you",
    "{target} cried in class again because of what {group} said",
    "guess what {target} did, biggest {insult} move of the year",
    "send the screenshot of {target} to everyone in {group}",
    "if you talk to {target} you're out of {group}",
    "{target} smells, sit somewhere else {target}",
    "{target} has no friends and never will",
    "the whole of {group} voted and {target} is the {insult} one",
    "stop trying to sit with us {target}, you're {insult}",
    "{target} should just change schools honestly",
]

POSITIVES_AR = [
    "كل {group} يقولون إنك {insult} يا {target}",
    "{target} ما عنده ولا صديق، محد يطيقهم",
    "شفتوا شنو لبس {target} اليوم؟ {insult}",
    "سوينا قروب بس عشان نضحك على {target}",
    "محد في {group} يحبك يا {target} خلاص افهم",
    "لا تردون على {target}، اليوم كلنا نتجاهله",
    "منو قال لك تدخل الشات يا {target}؟ محد عزلك",
    "{target} بكى في الحصة بسبب كلام {group}",
    "خمنوا شنو سوى {target}؟ أكبر حركة {insult} في السنة",
    "ارسلوا سكرين شوت كلام {target} لكل {group}",
    "إذا تكلمت مع {target} تطلع من {group}",
    "{target} ريحته خايسة، اقعد بعيد",
    "{target} ما عنده أصدقاء ولن يكون له",
    "{group} كله صوّت و{target} هو {insult}",
    "لا تحاول تقعد معنا يا {target}، إنت {insult}",
    "{target} الأفضل ينتقل مدرسة ثانية",
]

SLOTS_EN = {
    "target": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    "group": ["7B", "the team", "our class", "the group", "the squad", "year 9"],
    "insult": ["a joke", "pathetic", "so dumb", "a loser", "embarrassing", "a freak", "worthless"],
}

SLOTS_AR = {
    "target": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هنا", "بلال"],
    "group": ["الصف", "الفريق", "الشلة", "القروب", "صف سابع", "المدرسة"],
    "insult": ["مهزلة", "غبي", "فاشل", "محرج", "مقرف", "ما يسوى شي"],
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
