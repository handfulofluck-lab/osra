"""grooming bank -- secrecy, flattery, isolation, gifts, private meetings.

The pattern here is social, not sexual: an adult or older teen positioning
themselves as the only person who understands the child. Every template turns
on one of the tells a detector can actually learn -- "don't tell your mum",
"you're mature for your age", "your friends are holding you back", a gift with
a condition attached, a meeting alone at night, a photo "just for me", an
age-gap romance framed as nobody's business. There is no explicit content by
design: a detector that only fires on sexual vocabulary misses the months of
grooming that come before it.

Register: the way a 12-15 year old actually reads a message from someone they
are being pulled towards -- short, no capitals, no full stops. The Arabic is
MSA with Gulf school register, the same voice.
"""

CATEGORY = "grooming"

AGE_RANGE = (11, 16)

POSITIVES_EN = [
    "don't tell your mum about us {name}, she wouldn't get it",
    "delete these messages before your parents see them {name}",
    "this stays between us {name}, don't put it in the family group",
    "you're so mature for your age {name}, nothing like the boys in your class",
    "you're not like the other girls your age {name}, that's why i chose you",
    "i'll get you {gift} if you keep this quiet {name}",
    "i'll send you {gift} as a surprise, just don't tell anyone where it came from",
    "why are you still hanging out with {friend}? she's holding you back {name}",
    "your friends don't get you like i do {name}",
    "if {friend} keeps messaging you i'll stop talking to you",
    "meet me {place} {time} {name}, just you, nobody else needs to know",
    "come alone {time} {name}, leave your phone at home so nobody can track you",
    "don't bring {friend}, i want it to be just us {time}",
    "send me a photo of you before bed {name}, just for me",
    "you can trust me {name}, send the pic and i'll delete it right after",
    "take the photo in your room {name}, no one has to see",
    "age is just a number {name}, nobody needs to know how old i am",
    "if anyone asks, we say you're 16 {name}",
    "you're 14? that's fine {name}, you're more grown up than girls my age",
    "{older} has a car and he wants to see you {name}",
    "{older} says you're pretty {name}, he wants your number",
]

POSITIVES_AR = [
    "لا تقولين لأمك عنا يا {name}، هي ما راح تفهم",
    "امسحي الرسائل قبل لا يشوفها أهلك يا {name}",
    "هذا بيني وبينك يا {name}، لا تحطينه في قروب العائلة",
    "إنت ناضجة أكثر من عمرك يا {name}، مو مثل عيال صفك",
    "إنت غير عن كل البنات في عمرك يا {name}، عشان كذا اخترتك",
    "أقدر أجيب لك {gift} إذا سكتّي عن الموضوع يا {name}",
    "بأرسل لك {gift} مفاجأة، بس لا تقولين من وين جاءت",
    "ليش بعدك تقعدين مع {friend}؟ هي بس تأخرك يا {name}",
    "صديقاتك ما يفهمونك مثل ما أفهمك يا {name}",
    "إذا {friend} بعدها تراسلك، أنا بوقف أكلمك",
    "نتقابل {place} {time} يا {name}، بس إنت وأنا، محد يحتاج يعرف",
    "تعالي لحالك {time} يا {name}، خلي تلفونك في البيت عشان محد يتتبعك",
    "لا تجيبين {friend} معك، أبغى نكون لحالنا {time}",
    "أرسلي لي صورة لك قبل لا تنامين يا {name}، بس لي أنا",
    "ثقيني يا {name}، أرسلي الصورة وأنا بمسحها على طول",
    "خذي الصورة في غرفتك يا {name}، محد لازم يشوف",
    "العمر مجرد رقم يا {name}، محد لازم يعرف كم عمري",
    "إذا أحد سأل، نقول إن عمرك ١٦ يا {name}",
    "عمرك ١٤؟ عادي يا {name}، إنت أنضج من بنات عمري",
    "{older} عنده سيارة ويبي يشوفك يا {name}",
    "{older} يقول إنك حلوة يا {name}، يبي رقمك",
]

SLOTS_EN = {
    "name": ["Sara", "Layla", "Hana", "Noor", "Mariam", "Dana", "Rania", "Aisha"],
    "gift": ["a new phone", "an iPhone", "new trainers", "a gift card",
             "perfume", "a gold bracelet", "airpods", "makeup"],
    "friend": ["Layla", "Dana", "your best friend", "Sara", "Hana", "Mariam"],
    "place": ["at the park", "behind the shops", "in the mall car park",
              "at the cafe near school", "at the end of the street",
              "by the gate behind the school"],
    "time": ["at midnight", "after everyone's asleep", "around 11", "late tonight",
             "after your mum goes to bed", "when the house is quiet"],
    "older": ["a guy from uni", "a guy who's 19", "my cousin's friend who's 21",
              "an older guy from the gym", "a guy at my work",
              "a guy from the football group"],
}

SLOTS_AR = {
    "name": ["سارة", "ليلى", "هنا", "نور", "مريم", "دانة", "رنا", "عايشة"],
    "gift": ["تلفون جديد", "آيفون", "جزمة جديدة", "بطاقة هدايا",
             "عطر", "أسورة ذهب", "سماعات", "مكياج"],
    "friend": ["ليلى", "دانة", "صديقتك", "سارة", "هنا", "مريم"],
    "place": ["في الحديقة", "ورا المحلات", "في مواقف المول",
              "في الكافيه اللي جنب المدرسة", "في نهاية الشارع",
              "في الحديقة اللي ورا بيتكم"],
    "time": ["بعد نص الليل", "بعد ما ينامون كلهم", "الساعة ١١", "الليلة متأخر",
             "بعد ما تنام أمك", "لما البيت يهدأ"],
    "older": ["واحد من الجامعة", "شاب عمره ١٩", "صاحب ولد خالتك عمره ٢١",
              "واحد أكبر من النادي", "واحد يشتغل معانا", "شاب من قروب الكورة"],
}

# Hard negatives reuse the trigger vocabulary -- secret, gift, photo, meet,
# alone, night, older, delete -- in the ordinary life of a school kid. A scorer
# that keys on one word fires here, and that precision cost should be visible.
HARD_NEGATIVES_EN = [
    "don't tell mum about the cake, it's a surprise for friday",
    "keep the gift secret, it's for dad's birthday",
    "delete these photos before my storage fills up",
    "we're meeting at the park at 6 for football practice",
    "my older cousin is picking me up from school today",
    "i sent my friend a photo of the homework page",
    "the surprise party is at night so everyone can come",
    "i want to walk home alone today, i need to think",
    "mum said i'm mature for my age because i finished the project early",
    "my sister keeps borrowing my charger without asking",
    "the family group chat is just mum sending good morning pictures",
    "coach says i need to practise alone before the match",
    "i'll send you the notes later, my phone is almost dead",
    "the new girl in class is nice, i sat with her at lunch",
]

HARD_NEGATIVES_AR = [
    "لا تقولين لأمي عن الكيكة، بنسوي لها مفاجأة الجمعة",
    "خلي الهدية سر، عيد ميلاد أبوي بكرة",
    "امسحي الصور قبل لا يمتلي التخزين عندي",
    "بنتقابل في الحديقة الساعة ٦ لتدريب الكورة",
    "ولد خالتي الكبير بيوصلني من المدرسة اليوم",
    "أرسلت لصديقي صورة صفحة الواجب",
    "حفلة المفاجأة بالليل عشان الكل يقدر يجي",
    "أبي أمشي البيت لحالي اليوم، محتاج أفكر",
    "أمي تقول إني ناضج بالنسبة لعمري لأني خلصت المشروع بدري",
    "أختي تاخذ الشاحن حقي بدون ما تقول",
    "قروب العائلة كله صور صباح الخير من أمي",
    "المدرب يقول لازم أتدرب لحالي قبل المباراة",
    "بأرسل لك الملاحظات بعدين، تلفوني بيخلص شحن",
]

GENERIC_SAFE_EN = [
    "do you want to study for the maths test together tomorrow",
    "i got the new football boots and they fit finally",
    "mum says i have to be home by eight tonight",
    "did the teacher post the homework answers yet",
    "we're watching the match at my place on friday if you want to come",
    "my project on volcanoes is almost finished",
    "dinner is at seven, come down when you're done",
]

GENERIC_SAFE_AR = [
    "تبي ندرس للاختبار الرياضيات باجر سوا",
    "شريت جزمة الكورة الجديدة ومقاسها ضبط أخيراً",
    "أمي تقول لازم أرجع البيت الساعة ثمان",
    "الأستاذ نزّل حل الواجب ولا لا",
    "بنتفرج المباراة عندنا يوم الجمعة إذا تبي تجي",
    "مشروعي عن البراكين خلص تقريباً",
    "العشاء الساعة سبع، انزل لما تخلص",
]
