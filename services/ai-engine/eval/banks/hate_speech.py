"""hate_speech bank -- group-targeted contempt, dehumanising labels, recruitment.

The pattern is not a single insult word but a stance: a group is named, described
as less than human (vermin, parasites, a plague), and that description is used to
justify exclusion ("they don't belong here"), in-group policing ("if you're
friends with them you're one too"), secrecy ("don't tell your parents"), and
recruitment into a channel that "tells the truth". The "it's just a joke" line
is included because that is how the same content arrives in a school chat.

Epithets are kept as short lexical tokens inside ordinary bullying or recruitment
sentences, groups are generic (no real named person, no real organisation), and
there is no method, no target list, no instruction. Hard negatives are the two
contexts that must not fire: quoting a slur while studying propaganda, and
reclaimed self-labelling.
"""

CATEGORY = "hate_speech"

AGE_RANGE = (11, 17)

POSITIVES_EN = [
    "{group} are {slur}, they don't belong in our school",
    "why are {group} even allowed here, they're {slur}",
    "don't sit with {group} at lunch, they're {slur} and everyone knows it",
    "someone should teach {group} a lesson, they're not like us",
    "{group} are {slur}, this country was better before they came",
    "we don't talk to {group}, they're {slur}, all of them",
    "our people are the only real ones, {group} are {slur}",
    "if you're friends with {group} you're {slur} too",
    "this chat is for us only, {group} are {slur} and they can't come in",
    "make a meme about {group} and call them {slur}, everyone will share it",
    "you're one of us now, don't tell your parents about the group",
    "delete this after you read it, {group} are {slur} and we're going to stop them",
    "we meet behind {place} after dark, don't bring anyone from {group}",
    "don't tell anyone about us, they'll say we hate {group} but we're just telling the truth",
    "{group} are {slur}, it's just a joke, why is everyone so sensitive",
    "laugh at {group} with me, they're {slur}, it's only banter",
    "join our channel, it's the only place that tells the truth about {group}",
    "{group} should go back to where they came from, they're {slur}",
]

POSITIVES_AR = [
    "{group} {slur}، ما لهم مكان في مدرستنا",
    "ليش {group} موجودين أصلاً؟ كلهم {slur}",
    "لا تقعدون مع {group} في الفسحة، كلهم {slur}",
    "أحد لازم يعلّم {group} الأدب، مو مثلنا",
    "{group} {slur}، البلد كان أحسن قبل ما يجون",
    "ما نتكلم مع {group}، كلهم {slur}",
    "احنا بس الأصليين، {group} {slur}",
    "إذا تصاحب {group} إنت بعد {slur}",
    "القروب حقنا بس، {group} {slur} وما يدخلون",
    "سوّوا ميم على {group} وخلوها تضحك، كلهم {slur}",
    "إنت منا الحين، لا تقول لأهلك عن القروب",
    "امسح الرسالة بعد ما تقراها، {group} {slur} ولازم نوقفهم",
    "نتقابل ورا {place} بعد المغرب، لا تجيب أحد من {group}",
    "لا تقول لأحد عنّا، بيقولون عنا كارهين، احنا بس نقول الحقيقة",
    "{group} {slur}، عادي مزح، ليش كلكم حساسين",
    "اضحك معاي على {group}، كلهم {slur}، هذا مزح بس",
    "ادخل قناتنا، هذا المكان الوحيد اللي يقول الحقيقة عن {group}",
    "{group} لازم يرجعون من وين جو، كلهم {slur}",
]

SLOTS_EN = {
    "group": ["the new kids", "that family in flat 4", "the kids from the other side",
              "the refugees in our year", "the girls in robotics club", "the kids on the bus",
              "the boys from the estate", "the kids who pray at lunch"],
    "slur": ["vermin", "parasites", "animals", "trash", "scum", "freaks", "diseased", "a plague"],
    "place": ["the shops", "the old pitch", "the car park", "the rec", "the station", "the back gate"],
}

SLOTS_AR = {
    "group": ["الطلاب الجدد", "العائلة اللي سكنت في العمارة", "الوافدين في صفنا",
              "الأولاد اللي ما يتكلمون لغتنا", "بنات نادي الروبوت", "الطلاب اللي يصلون في المدرسة",
              "أهل الحي الثاني", "الطلاب اللي جو من مدرسة ثانية"],
    "slur": ["حشرات", "حيوانات", "وباء", "زبالة", "أوباش", "طفيليات", "قذرين", "مرض"],
    "place": ["السوق", "الملعب القديم", "المواقف", "الحديقة", "المحطة", "الباب الخلفي"],
}

HARD_NEGATIVES_EN = [
    "in history we read a 1930s speech that called a whole group vermin, we're analysing the propaganda",
    "our english essay is about why calling people animals on war posters works, the teacher gave us the quotes",
    "the teacher said don't repeat the slur in class, just say the slur when we quote it",
    "we watched a documentary about dehumanising language in the holocaust unit, it was heavy",
    "my friend group is literally called the freaks and we picked the name ourselves",
    "I call myself a nerd and I've fully reclaimed it, it's mine now",
    "she uses that word about herself and says it's her label, so I don't use it",
    "I reported a comment in the game that called people parasites, the mod deleted it in a minute",
    "our debate topic is whether hate speech should be illegal, I'm on the free speech side",
    "the book's villain calls the villagers scum, we have to write about what that tells us about him",
    "the anti-bullying assembly showed examples of slurs so we'd know what to report",
    "my uncle explained that the old word for our family was used as an insult, so he told us the history",
]

HARD_NEGATIVES_AR = [
    "في التاريخ قرينا خطاب قديم يوصف مجموعة بالحشرات، كنا نحلل أسلوب الدعاية",
    "موضوع التعبير عن الحرب، ليش وصف الناس بالحيوانات يخليهم يصدقون؟ الأستاذ أعطانا الاقتباسات",
    "الأستاذة قالت لا نعيد الإهانة في الصف، نقول الكلمة وبس",
    "درسنا كيف استخدموا كلمة طفيلي ضد المهاجرين قبل مئة سنة",
    "قروب أصحابي اسمه المجانين واحنا اخترنا الاسم بأنفسنا",
    "أنا أسمي نفسي الدب وأفتخر، ما أعتبرها إهانة",
    "هي تستخدم الكلمة على نفسها وتقول هذي هويتها، فما أستخدمها أنا",
    "بلّغت عن تعليق في اللعبة يوصف ناس بالوباء، المشرف حذفه",
    "موضوع المناظرة عندنا هل خطاب الكراهية لازم يكون مخالف للقانون",
    "الكتاب فيه شرير ينعت أهل القرية بالزبالة، لازم نكتب شنو يعني هذا عنه",
    "الندوة عن التنمر عرضت أمثلة عشان نعرف شنو نبلّغ عنه",
]

GENERIC_SAFE_EN = [
    "got the new boots finally, they fit perfect",
    "mum says dinner's at seven so come over after",
    "did you finish the science sheet or is it just me",
    "we're playing football at the park after school, come",
    "the maths homework was actually easy today",
    "my sister ate my snack again, I'm telling mum",
    "the bus was late so I missed first period",
    "are you going to the match on friday",
]

GENERIC_SAFE_AR = [
    "شريت الجزمة الجديدة وأخيراً ضبط المقاس",
    "أمي تقول العشا الساعة سبع، تعال بعدها",
    "خلصت ورقة العلوم ولا باقي عليك",
    "بنلعب كورة في الحديقة بعد المدرسة، تعال",
    "واجب الرياضيات اليوم كان سهل",
    "أختي أكلت سندويتشي مرة ثانية، بقول لأمي",
    "الباص تأخر وفاتتني الحصة الأولى",
    "بتروح المباراة يوم الجمعة",
]
