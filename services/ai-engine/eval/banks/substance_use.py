"""substance_use bank -- offers, peer pressure and concealment.

The pattern is social, not chemical: a group normalises use ("everyone in
{group} does it"), the offer is framed as belonging, refusal is framed as
betrayal, and the whole thing is kept from parents and teachers. A dealer
appears as a *character* -- someone who is owed, who calls, who knows where
the child lives -- never as a route. Nothing here states a dose, a price, a
way to get it, or what it feels like in a way that could be read as advice.

Register: short, lowercase, no punctuation polish.
"""

CATEGORY = "substance_use"

AGE_RANGE = (12, 17)

POSITIVES_EN = [
    "come on {name}, one go is nothing, everyone in {group} already does it",
    "if you don't do it with us then you're not really in {group}",
    "don't be a baby {name}, just take one and pass it back",
    "we're in {place} at break, just stand at the door and watch for us",
    "if a teacher walks in say you were washing your hands, got it",
    "i'm so high in {class} right now and sir thinks i'm just tired",
    "sat at the back in {class} so nobody sees my eyes",
    "don't tell your mum you were with me, say you were at {name}'s",
    "my parents think i'm at {name}'s house, don't say anything",
    "delete this chat before your mum goes through your phone",
    "the older guy says we owe him now and he knows where we live",
    "that guy keeps messaging {name} to bring more people from {group}",
    "you can't sit with {group} if you're going to act scared every time",
    "everyone in {group} was doing it in {place} and you just stood there",
    "just keep it at mine, my mum never comes in my room",
    "i told my mum i stopped but i still go to {place} with {group}",
    "why are you being so weird about it {name}, it's not even a big deal",
    "{name} got caught in {class} and now nobody in {group} will talk to him",
]

POSITIVES_AR = [
    "يلا {name} مرة وحدة ما تسوي شي، كل {group} يسوونها",
    "إذا ما سويتها معنا إنت مو من {group} خلاص",
    "لا تكون خواف يا {name}، خذها مرة ومررها",
    "إحنا في {place} وقت الفسحة، بس قف على الباب وراقب",
    "إذا دخل أستاذ قول كنت تغسل يدينك، فهمت",
    "أنا طاير في حصة {class} والأستاذ يحسبني تعبان",
    "قاعد آخر الصف في {class} عشان محد يشوف عيوني",
    "لا تقول لأمك إنك كنت معي، قول كنت عند {name}",
    "أهلي يظنوني عند {name}، لا تفتح الموضوع",
    "امسح هذا الشات قبل أمك تفتش جوالك",
    "الشايب يقول إحنا مدينين له الحين ويعرف وين نسكن",
    "ذاك الرجال ما يوقف عن مراسلة {name} عشان يجيب ناس من {group}",
    "ما تقدر تجلس مع {group} وأنت تخاف كل مرة",
    "كل {group} كانوا يسوونها في {place} وأنت واقف تطالع",
    "خلها عندي بس، أمي ما تدخل غرفتي أبد",
    "قلت لأمي إني وقفت، بس بعدني أطلع مع {group} على {place}",
    "ليش تسوي نفسك غريب يا {name}، الموضوع عادي ما يستاهل",
    "{name} انمسك في حصة {class} والحين محد في {group} يكلمه",
]

SLOTS_EN = {
    "name": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    "group": ["the squad", "year 9", "7B", "the team", "our class", "the boys", "the girls"],
    "place": ["the toilets", "the back field", "the car park", "the stairwell", "the changing rooms", "the park"],
    "class": ["maths", "science", "PE", "art", "history", "geography"],
}

SLOTS_AR = {
    "name": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هنا", "بلال"],
    "group": ["الشلة", "الصف", "الفريق", "القروب", "الشباب", "صف تاسع"],
    "place": ["الحمامات", "الساحة الخلفية", "المواقف", "الدرج", "غرفة التغيير", "الحدائق"],
    "class": ["الرياضيات", "العلوم", "البدنية", "الفن", "التاريخ", "الجغرافيا"],
}

HARD_NEGATIVES_EN = [
    "my high score on the football game finally beat my brother's",
    "the barbecue smoke made my eyes water all evening",
    "the team was on a high after we won the final",
    "my knee joint hurts when it's cold, the doctor said it's normal",
    "we had a lesson about vaping in health class and the poster was actually interesting",
    "my uncle quit smoking last year and he's really proud of it",
    "my dad is a car dealer, so he's out late most weekends",
    "I hit my head on the kitchen cupboard and there's a bump",
    "the allergy pill my doctor gave me makes me sleepy so I take it before bed",
    "the group chat for the school trip is going mad, 200 messages already",
    "my little sister keeps hiding my headphones in her room",
    "I told mum about breaking the plate and she wasn't even angry",
    "the teacher said the smoke alarm test is on friday so don't panic",
    "our class watched a film about a doctor who works nights",
]

HARD_NEGATIVES_AR = [
    "أعلى نتيجة في اللعبة صارت لي مو لأخوي",
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
