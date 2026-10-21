"""grooming bank -- an adult or older teen positioning himself as the child's only ally.

The pattern is social, not sexual: an age gap the child is asked to keep quiet
about. Every template names that gap in the message itself -- "i'm 25 and you're
13", "a guy from the game who's 27", "an older guy from the mall", "when your mum
is out" -- and attaches the secrecy to it ("don't tell your mum about me",
"delete our chat"), because a bare secrecy line is not labelable: "delete this
chat before your mum sees it" says nothing about who is talking to whom (#262
review). The other tells a detector can learn are all here and all tied to the
gap: flattery ("you're so mature for 13"), isolation from friends, a gift with
strings, a meeting alone, and a photo "just for me".

Everything stays at the pattern level. There is no sexual content, no method and
no meeting instructions beyond "alone" and "quiet": a detector that only fires
on explicit vocabulary misses the months of grooming that come before it.

The Arabic is Gulf school register with MSA wording -- MSA verb forms and
pronouns, Gulf everyday nouns (المول، تلفون، اللعبة) -- the same voice a 12-15
year old would use. Targets come in gendered pairs (target_m/target_f) because
the imperative, the pronoun and the possessive all agree; a single mixed slot
would produce "يا سارة، امسح محادثتنا".

Image requests carry `sexual_content` as a second label: an adult asking a child
for a photo in the child's room is both grooming and a sexual request, and a
scorer that answers one of the two is not wrong.
"""

CATEGORY = "grooming"

AGE_RANGE = (11, 16)

POSITIVES_EN = [
    "hey {target}, you're 13 and i'm {age}, that's our business, don't tell your mum about me",
    "delete our chat {target}, i'm {age}, if your mum reads it she'll stop us talking",
    "i'm {age} and you're 13 {target}, age is just a number, just don't tell anyone about us",
    "meet me {place} {time} {target}, i'm {age} and nobody needs to know about us",
    "come alone {time} {target}, i'm {age}, leave your phone at home so your mum can't track you",
    "i'll get you {gift} {target}, i'm {age}, just don't tell your mum where it came from",
    "you're so mature for 13 {target}, that's why i'm {age} and i picked you",
    "your friends are all 13 {target}, they won't get us, don't tell them about me, i'm {age}",
    "don't bring {friend} {time} {target}, i'm {age} and i want it just us, no one needs to know",
    "if your mum asks where you were {target}, say you were at {friend}'s, not with me, i'm {age}",
    "a guy from the game who's {age} keeps asking me to meet up, he says don't tell my mum",
    "an older guy from the mall got my number and said not to tell my mum about him",
    "the man from the game is {age} and he wants to meet me when my mum's out",
    "send me a photo of you in your room {target}, i'm {age}, just for me, no one has to see",
    "take the pic before bed {target}, i'm {age} and i'll delete it after, i promise",
    "trust me {target}, send the photo and i'll keep it between us, i'm {age}, it's fine",
    "{target_m} is meeting a guy from the game who's {age}, he told him not to tell his mum",
    "{target_f} is meeting a guy from the game who's {age}, he told her not to tell her mum",
    "a man who's {age} added {target_m} from the game and told him to delete the chat",
    "a man who's {age} added {target_f} from the game and told her to delete the chat",
]

POSITIVES_AR = [
    "يا {target_m}، عمرك ١٣ وعمري {age}، هذا بيننا، لا تخبر أمك عني",
    "يا {target_f}، عمرك ١٣ وعمري {age}، هذا بيننا، لا تخبري أمك عني",
    "امسح محادثتنا يا {target_m}، عمري {age}، إذا قرأت أمك الرسائل ستمنعنا من الكلام",
    "امسحي محادثتنا يا {target_f}، عمري {age}، إذا قرأت أمك الرسائل ستمنعنا من الكلام",
    "يا {target_m}، نتقابل {place} {time}، عمري {age} ولا أحد يحتاج أن يعرف عنا",
    "يا {target_f}، نتقابل {place} {time}، عمري {age} ولا أحد يحتاج أن يعرف عنا",
    "تعال وحدك {time} يا {target_m}، عمري {age}، اترك تلفونك في البيت كي لا تعرف أمك مكانك",
    "تعالي وحدك {time} يا {target_f}، عمري {age}، اتركي تلفونك في البيت كي لا تعرف أمك مكانك",
    "سأحضر لك {gift} يا {target_m}، عمري {age}، فقط لا تخبر أمك بالهدية",
    "سأحضر لك {gift} يا {target_f}، عمري {age}، فقط لا تخبري أمك بالهدية",
    "أنت ناضج أكثر من عمرك يا {target_m}، لهذا اخترتك أنا وعمري {age}",
    "أنت ناضجة أكثر من عمرك يا {target_f}، لهذا اخترتك أنا وعمري {age}",
    "لا تحضر {friend} معك {time} يا {target_m}، عمري {age} وأريد أن نكون وحدنا",
    "لا تحضري {friend} معك {time} يا {target_f}، عمري {age} وأريد أن نكون وحدنا",
    "أرسل لي صورة لك في غرفتك يا {target_m}، عمري {age}، فقط لي، لا أحد يجب أن يراها",
    "أرسلي لي صورة لك في غرفتك يا {target_f}، عمري {age}، فقط لي، لا أحد يجب أن يراها",
    "خذ الصورة قبل النوم يا {target_m}، عمري {age} وسأمسحها بعد ذلك، أعدك",
    "خذي الصورة قبل النوم يا {target_f}، عمري {age} وسأمسحها بعد ذلك، أعدك",
    "إذا سألت أمك أين كنت يا {target_m}، قل إنك كنت عند {friend}، وليس معي، عمري {age}",
    "إذا سألت أمك أين كنت يا {target_f}، قولي إنك كنت عند {friend}، وليس معي، عمري {age}",
    "شاب من اللعبة عمره {age} يريد أن يقابلني ويطلب مني ألا أخبر أمي",
    "رجل أكبر مني من المول أخذ رقمي وطلب مني ألا أخبر أمي عنه",
    "شخص من اللعبة عمره {age} يريد أن يراني عندما تكون أمي خارج البيت",
]

SLOTS_EN = {
    "target": ["Sara", "Layla", "Hana", "Noor", "Mariam", "Dana", "Omar", "Adam"],
    # Only templates that refer to the child in the third person use the gendered pair.
    "target_m": ["Omar", "Adam", "Yousef", "Bilal", "Kareem", "Ziad"],
    "target_f": ["Sara", "Layla", "Noor", "Hana", "Mariam", "Dana"],
    "age": ["25", "26", "27", "24", "28", "31"],
    "gift": ["a new phone", "airpods", "new trainers", "a gift card",
             "perfume", "a gold bracelet"],
    # Disjoint from the name slots: a fill must not produce "don't bring Layla ... Layla".
    "friend": ["Rania", "Yara", "your best friend", "Salma", "Aisha", "Mona"],
    "place": ["at the park", "behind the shops", "in the mall car park",
              "at the cafe near school", "by the gate behind the school",
              "at the end of the street"],
    "time": ["when your mum's out", "when your mum's at work", "after everyone's asleep",
             "at midnight", "late tonight", "when the house is empty"],
}

SLOTS_AR = {
    # Every Arabic template names the child in the second person, so each one uses one
    # side of the pair: the imperative and the possessive agree with the name.
    "target_m": ["عمر", "آدم", "يوسف", "بلال", "كريم", "زياد"],
    "target_f": ["سارة", "ليلى", "نور", "هناء", "مريم", "دانة"],
    "age": ["٢٥", "٢٦", "٢٧", "٢٤", "٢٨", "٣١"],
    "gift": ["تلفون جديد", "سماعات", "جزمة جديدة", "بطاقة هدايا", "عطر", "أسورة ذهب"],
    "friend": ["رنا", "يارا", "سلمى", "عايشة", "منى", "هيفاء"],
    "place": ["في الحديقة", "خلف المحلات", "في مواقف المول", "في المقهى قرب المدرسة",
              "عند بوابة المدرسة الخلفية", "في نهاية الشارع"],
    "time": ["عندما تكون أمك خارج البيت", "عندما تذهب أمك إلى العمل", "بعد أن ينام الجميع",
             "في منتصف الليل", "بعد المدرسة عندما يكون البيت فارغاً", "في وقت متأخر من الليل"],
}

# An adult asking a child for a photo of herself in her room is grooming *and* a
# sexual request; both readings are correct, so both labels are carried.
ALSO_LABELS_EN = {
    13: ["sexual_content"],
    14: ["sexual_content"],
    15: ["sexual_content"],
}

ALSO_LABELS_AR = {
    14: ["sexual_content"],
    15: ["sexual_content"],
    16: ["sexual_content"],
    17: ["sexual_content"],
}

# Hard negatives reuse the trigger vocabulary -- secret, gift, photo, meet,
# alone, night, older, delete, 25, the game -- in the ordinary life of a school
# kid. None of them has an adult talking to a child, so none is a real positive.
HARD_NEGATIVES_EN = [
    "don't tell mum about the cake, it's a surprise for friday",
    "keep the gift secret, it's for dad's birthday",
    "delete these photos before my storage fills up",
    "we're meeting at the park at 6 for football practice",
    "my older cousin is picking me up from school today",
    "i sent my friend a photo of the homework page",
    "the surprise party is at night so everyone can come",
    "i want to walk home alone today, i need to think",
    "mum says i'm mature for my age because i finished the project early",
    "i put 25 as my age on the game so i could join the older server",
    "a guy in the game was 25 and he gave me his build for the boss fight",
    "the family group chat is just mum sending good morning pictures",
    "coach says i need to practise alone before the match",
]

HARD_NEGATIVES_AR = [
    "لا تخبر أمي عن الكيكة، نحضر لها مفاجأة يوم الجمعة",
    "خلي الهدية سراً، إنها عيد ميلاد أبي",
    "امسح هذه الصور قبل أن يمتلئ التخزين عندي",
    "نتقابل في الحديقة الساعة ٦ لتدريب الكرة",
    "ابن خالتي الكبير سيأخذني من المدرسة اليوم",
    "أرسلت لصديقي صورة صفحة الواجب",
    "حفلة المفاجأة في الليل حتى يستطيع الجميع الحضور",
    "أريد أن أمشي إلى البيت وحدي اليوم، أحتاج أن أفكر",
    "أمي تقول إني ناضج بالنسبة لعمري لأني أنهيت المشروع مبكراً",
    "في حساب اللعبة كتبت أن عمري ٢٥ حتى ألعب في السيرفر المخصص للكبار",
    "شاب في اللعبة عمره ٢٥ ساعدني في المهمة ثم خرج، كان لطيفاً",
    "قروب العائلة كله صور صباح الخير من أمي",
    "المدرب يقول يجب أن أتدرب وحدي قبل المباراة",
]

GENERIC_SAFE_EN = [
    "do you want to study for the maths test together tomorrow",
    "i got the new football boots and they fit finally",
    "mum says i have to be home by eight tonight",
    "did the teacher post the homework answers yet",
    "we're watching the match at my place on friday if you want to come",
    "my project on volcanoes is almost finished",
    "can you bring the charger to school tomorrow",
]

GENERIC_SAFE_AR = [
    "هل ندرس لاختبار الرياضيات معاً غداً",
    "شريت جزمة الكرة الجديدة ومقاسها ضبط أخيراً",
    "أمي تقول لازم أرجع البيت الساعة ثمان",
    "هل نزّل الأستاذ حل الواجب",
    "سنتفرج المباراة عندنا يوم الجمعة إذا أردت المجيء",
    "مشروعي عن البراكين شبه منتهٍ",
    "تقدر تجيب الشاحن معك للمدرسة بكرة",
]
