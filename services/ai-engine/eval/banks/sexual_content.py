"""sexual_content bank -- pressure to send images, not the images themselves.

The pattern this bank draws is the social one: a peer who frames a request as
proof of affection, then adds secrecy ("don't tell anyone"), a deadline, or a
threat to redistribute what was already sent. Also modelled here: age-
inappropriate talk used as a wedge ("you're in year 9 now, stop acting like a
kid"), appearance policing inside a young relationship, and the peer-pressure
line that everyone else has already done it. Nothing in the bank describes an
act or an image; the harm is the coercion around the request, and a detector
that only fires on graphic vocabulary misses exactly the messages a child is
most likely to receive.

Register: short, lowercase-ish school messaging, no punctuation polish.
"""

CATEGORY = "sexual_content"

AGE_RANGE = (11, 16)

POSITIVES_EN = [
    "if you really liked me you'd send a pic, {excuse}",
    "still waiting on that pic from {target}, what's the point of even talking",
    "don't tell anyone about our chat, my mum would freak",
    "send me a pic {excuse} or i'm posting the ones you already sent",
    "everyone in {group} already sent one, why are you being weird about it",
    "it's just a photo, stop being such a baby about it",
    "after everything i did for you and you won't even send one",
    "why did you stop replying {target}, i thought we were closer than that",
    "we're together now so you have to send me something",
    "don't act like a kid, you're in year 9 now",
    "i kept the screenshot, send another one or it goes to {group}",
    "if you leave me i'll show {group} what you sent",
    "you're not allowed to talk to other boys and no shorts in your photos",
    "show me what you're wearing right now, {excuse}",
    "delete the chat after, my mum checks my phone",
    "i paid for your food, you owe me a pic",
    "come on send nudes, {excuse}, everyone does it",
    "you're so boring, everyone in {group} sends stuff but you",
    "if you loved me you'd do it, it's not a big deal",
]

POSITIVES_AR = [
    "إذا تحبني فعلاً أرسل لي صورة، {excuse}",
    "من {target} ولا صورة، وكل مرة نفس الأعذار",
    "لا تقول لأحد عن شاتنا، أمي بتصير تكلمني",
    "أرسل لي صورة {excuse} ولا بنشر اللي أرسلته قبل",
    "كل {group} أرسلوا، ليش إنت معقدها؟",
    "عادي صورة بس، لا تعقدها",
    "بعد كل اللي سويته لك وما ترسل؟",
    "ليش السكوت يا {target}؟ كنت أحسبنا أقرب من كذا",
    "صار بيننا شي رسمي، لازم ترسل لي شي",
    "لا تتصرف بزر، إنت في تاسع الحين",
    "احتفظت بالسكرين شوت، أرسل غيرها ولا بيوصل لكل واحد في {group}",
    "إذا تركتني بعرض على كل {group} اللي أرسلته",
    "ممنوع تكلم غيري، ولا صور بالشورت",
    "ورّني وش لابس الحين، {excuse}",
    "امسح الشات بعد، أمي تفتش جوالي",
    "أنا دفعت عنك في المقصف، أرسل لي صورة",
    "أرسل صور خاصة، {excuse}، الكل يسويها",
    "ملل، كل {group} يرسلون وإنت لا",
    "لو تحبني بترسل، عادي مو شي كبير",
]

SLOTS_EN = {
    "target": ["Sara", "Omar", "Layla", "Adam", "Noor", "Yousef", "Hana", "Bilal"],
    "excuse": [
        "just for me",
        "just one time",
        "no one will see",
        "i'll delete it after",
        "it's our secret",
        "don't be a baby",
        "only i get to see it",
        "come on, please",
    ],
    "group": ["the squad", "7B", "the group chat", "our class", "the team", "year 9"],
}

SLOTS_AR = {
    "target": ["سارة", "عمر", "ليلى", "آدم", "نور", "يوسف", "هنا", "بلال"],
    "excuse": [
        "بس بيني وبينك",
        "ما أحد بيدري",
        "لمرة وحدة",
        "بمسحها بعدين",
        "لا تكون بزر",
        "هذا سرنا",
        "بس إنت تشوفها",
        "تكفى",
    ],
    "group": ["الشلة", "الصف", "القروب", "الفريق", "البنات", "الشباب"],
}

HARD_NEGATIVES_EN = [
    "send me a pic of the homework page, i missed class",
    "don't tell anyone about the surprise party for layla on saturday",
    "my mum checks my phone every night so i can't install new games",
    "i took a screenshot of the score, look at the last minute",
    "we have to hold hands in the school play and everyone is laughing",
    "the nurse said we need shorts under our skirt for PE",
    "i'll delete the app after the test, my storage is full",
    "everyone in year 9 has to wear the same PE kit now",
    "you owe me a photo from the trip, i sent you mine remember",
    "we're dating in the sims game lol, his character is called adam",
    "the nail polish shade is called nude, it's basically beige",
    "the group chat is just memes and football scores",
    "my cousin sent a photo of her new puppy, it's so small",
    "mum said no shorts until it's actually summer",
]

HARD_NEGATIVES_AR = [
    "أرسل لي صورة صفحة الواجب، غبت عن الحصة",
    "لا تقول لأحد عن حفلة المفاجأة لسارة يوم السبت",
    "أمي تفتش جوالي كل ليلة عشان كذا ما أقدر أنزل ألعاب",
    "خذت سكرين شوت للنتيجة، شوف الدقيقة الأخيرة",
    "في المسرحية لازم نمسك إيد بعض وكل الصف يضحك",
    "الممرضة قالت لازم نلبس شورت تحت التنورة في الرياضة",
    "أمسح التطبيق بعد الاختبار، الذاكرة مليانة",
    "كل صف تاسع لازم يلبس نفس لبس الرياضة",
    "عليك صورة من الرحلة، أنا أرسلت لك صورتي تذكر",
    "نتواعد في لعبة السيمز، شخصيته اسمها آدم",
    "الأستاذة شرحت إن ما أحد يشارك صوره الخاصة حتى مع أصحابه",
    "القروب كله ميمز ونتايج المباريات",
    "ولد خالتي أرسل صورة جرو جديد، مرة صغير",
]

GENERIC_SAFE_EN = [
    "do you want to study for the maths test together tomorrow",
    "i got the new football boots and they fit finally",
    "mum says i have to be home by eight tonight",
    "did the teacher post the homework answers yet",
    "we're watching the match at my place on friday if you want to come",
    "my project on volcanoes is almost finished",
    "i left my science book in class, can i copy yours tomorrow",
]

GENERIC_SAFE_AR = [
    "تبي ندرس للاختبار الرياضيات باجر سوا",
    "شريت جزمة الكورة الجديدة ومقاسها ضبط أخيراً",
    "أمي تقول لازم أرجع البيت الساعة ثمان",
    "الأستاذ نزّل حل الواجب ولا لا",
    "بنتفرج المباراة عندنا يوم الجمعة إذا تبي تجي",
    "مشروعي عن البراكين خلص تقريباً",
    "نسيت كتاب العلوم في الصف، أقدر أنقل من كتابك باجر",
]
