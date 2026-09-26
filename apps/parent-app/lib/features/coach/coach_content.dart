/// Feature #16: conversation-coach content DB (Qustodio-style guidance that
/// helps parents talk to their child after AI/social alerts).
///
/// NOTE: localized as paired `title`/`titleAr` (etc.) fields, not
/// flutter_localizations — the app toggles between the two inline.

/// One coaching card with paired English/Arabic strings.
class CoachCard {
  final String title;
  final String titleAr;
  final String body;
  final String bodyAr;
  final List<String> tips;
  final List<String> tipsAr;

  const CoachCard({
    required this.title,
    required this.titleAr,
    required this.body,
    required this.bodyAr,
    required this.tips,
    required this.tipsAr,
  });
}

/// Crisis-first: every sign is taken seriously, ask directly, professional
/// help numbers are a placeholder the family fills in locally.
const _selfHarm = CoachCard(
  title: 'If your child may be hurting themselves',
  titleAr: 'إذا كان طفلك قد يؤذي نفسه',
  body:
      'Take every sign seriously — mentions of self-harm are rarely "just for attention". '
      'Stay calm, choose a quiet moment, and ask directly: "Are you thinking about hurting yourself?" '
      'Asking openly does not plant the idea; it shows your child they can talk to you. '
      'Believe them, take their feelings seriously, and involve a mental-health professional as soon as possible. '
      'Crisis line / emergency number: [add local number].',
  bodyAr:
      'خذ كل مؤشر على محمل الجدّ؛ فالإشارات إلى إيذاء النفس نادرًا ما تكون «من أجل لفت الانتباه» فقط. '
      'ابقَ هادئًا، واختر وقتًا هادئًا، واسأل طفلك مباشرة: «هل تفكّر في إيذاء نفسك؟» '
      'فالسؤال الصريح لا يغرس الفكرة، بل يُظهر لطفلك أن بإمكانه الحديث معك. '
      'صدّقه، وخذ مشاعره بجدية، واستعن بمختص في الصحة النفسية في أقرب وقت. '
      'رقم الطوارئ أو الخط الساخن: [أضف الرقم المحلي].',
  tips: [
    'Stay calm and pick a quiet, private moment.',
    'Ask directly — open questions invite honesty.',
    'Listen without judging or minimizing their feelings.',
    'If there is immediate danger, stay with them and call emergency services: [add local number].',
    'Follow up with a counselor or doctor within days, not weeks.',
  ],
  tipsAr: [
    'ابقَ هادئًا واختر لحظة هادئة وخاصة.',
    'اسأل بشكل مباشر — فالأسئلة المفتوحة تشجّع على الصراحة.',
    'استمع دون إصدار أحكام أو التقليل من مشاعره.',
    'إذا كان هناك خطر داهم، ابقَ معه واتصل بخدمات الطوارئ: [أضف الرقم المحلي].',
    'تابع مع مرشد أو طبيب خلال أيام، لا أسابيع.',
  ],
);

const _grooming = CoachCard(
  title: 'When an adult may be grooming your child',
  titleAr: 'عندما يحاول شخص بالغ استغلال طفلك',
  body:
      'Online groomers build trust slowly: compliments, gifts, "jokes", then secrets and moving '
      'the chat to private channels. Your child is a victim, not at fault — never blame them for '
      'the contact. Keep the evidence: take screenshots and do not delete the conversation. Report '
      'and block the account, and if there were threats or sexual requests, contact the police or '
      'a child-protection hotline: [add local number].',
  bodyAr:
      'يمارس المستغلون الإلكترونيون الإغواء تدريجيًا: الإطراء ثم الهدايا ثم «الأسرار» ونقل المحادثة '
      'إلى قنوات خاصة. طفلك ضحية وليس المخطئ — لا تُلامه أبدًا على هذا التواصل. احتفظ بالأدلة: التقط '
      'لقطات شاشة ولا تحذف المحادثة. أبلغ عن الحساب واحظره، وإذا وُجدت تهديدات أو طلبات جنسية فتواصل '
      'مع الشرطة أو خط حماية الطفل: [أضف الرقم المحلي].',
  tips: [
    'Reassure your child: "You are not in trouble — I am glad you told me."',
    'Save screenshots; do not delete chats or block before preserving evidence.',
    'Report the account to the platform and block it.',
    'Watch for secrecy, gifts, and requests to move to private apps.',
    'Contact police or a child-protection line if requests were sexual or threatening: [add local number].',
  ],
  tipsAr: [
    'اطمئن طفلك: «أنت لست في مشكلة — وسعيد أنك أخبرتني».',
    'احفظ لقطات الشاشة؛ لا تحذف المحادثات ولا تحظر قبل حفظ الأدلة.',
    'أبلغ عن الحساب إلى المنصة ثم احظره.',
    'انتبه للأسرارية والهدايا وطلبات الانتقال إلى تطبيقات خاصة.',
    'تواصل مع الشرطة أو خط حماية الطفل إذا كانت الطلبات جنسية أو تهديدية: [أضف الرقم المحلي].',
  ],
);

const _cyberbullying = CoachCard(
  title: 'If your child is being bullied online',
  titleAr: 'إذا كان طفلك يتعرض للتنمر الإلكتروني',
  body:
      'Listen first. Confiscating the phone as a first response punishes the child and closes the '
      'conversation — the bullying is not their fault. Let them tell the whole story, write down '
      'what happened with dates and screenshots, then block and report the bully together. If '
      'classmates are involved, contact the school; persistent threats should go to the platform '
      'and, if serious, to the police.',
  bodyAr:
      'استمع أولًا. فمصادرة الهاتف كرد فعل أول يعاقب الطفل ويغلق باب الحوار — والتنمر ليس خطأه. '
      'دعه يحكي القصة كاملة، وسجّل ما حدث بالتواريخ ولقطات الشاشة، ثم احظر المتنمر وأبلغ عنه معًا. '
      'إذا كان المتنمر من زملائه فتواصل مع المدرسة، والتهديدات المستمرة تُبلَّغ إلى المنصة وإلى '
      'الشرطة إذا كانت خطيرة.',
  tips: [
    'Listen without interrupting; thank them for telling you.',
    'Do not remove their device as the first step — it isolates them further.',
    'Document everything: screenshots, dates, usernames.',
    'Block and report the bully on the platform.',
    'Involve the school when classmates are part of it.',
  ],
  tipsAr: [
    'استمع دون مقاطعة، واشكره لأنه أخبرك.',
    'لا تسلب جهازه كخطوة أولى — فذلك يزيده عزلة.',
    'وثّق كل شيء: لقطات الشاشة والتواريخ وأسماء المستخدمين.',
    'احظر المتنمر وأبلغ عنه على المنصة.',
    'تدخّل المدرسة عندما يكون الزملاء طرفًا في الأمر.',
  ],
);

const _sexualContent = CoachCard(
  title: 'Talking about sexual content',
  titleAr: 'الحديث عن المحتوى الجنسي',
  body:
      'Answer with age-appropriate honesty — children who get answers at home ask the internet '
      'less. Frame the issue as safety, not shame: their body, their privacy, and never sharing '
      'images of themselves. If they received something unwanted, stay calm and focus on who sent '
      'it and blocking it, not on punishing them for seeing it.',
  bodyAr:
      'أجب بصراحة مناسبة لعمره — فالأطفال الذين يجدون الإجابة في البيت يسألون الإنترنت أقل. '
      'اجعل الموضوع سلامة لا عيبًا: جسده وخصوصيته، وعدم إرسال صور لأنفسهم أبدًا. إذا تلقى محتوى '
      'غير مرغوب فابقَ هادئًا وركّز على من أرسله وحظره، لا على معاقبته لأنه رآه.',
  tips: [
    'Use correct, calm words — shame silences children.',
    'Explain that private images are never to be sent or requested.',
    'Agree on a no-questions-asked rule for reporting weird messages.',
    'Check privacy settings and block unknown contacts together.',
  ],
  tipsAr: [
    'استخدم كلمات صحيحة وهادئة — فالخجل يصمت الأطفال.',
    'اشرح أن الصور الخاصة لا يجوز إرسالها أو طلبها أبدًا.',
    'اتفقا على قاعدة «أخبرني بلا أسئلة» عند استلام رسائل غريبة.',
    'راجعا إعدادات الخصوصية واحظرا جهات الاتصال المجهولة معًا.',
  ],
);

const _violence = CoachCard(
  title: 'If your child sees or shares violent content',
  titleAr: 'إذا شاهد طفلك محتوى عنيفًا أو شاركه',
  body:
      'Stay curious, not angry. Ask what they saw and how it made them feel; repeated or excited '
      'consumption of violent content is a signal worth understanding, not just blocking. Explain '
      'the difference between fiction and real harm, set clear expectations, and talk to the '
      'school if it involves classmates or fights.',
  bodyAr:
      'كن فضوليًا لا غاضبًا. اسأل عمّا شاهده وكيف شعر تجاهه؛ فتكرار مشاهدة المحتوى العنيف أو '
      'التفاعل معه بحماس إشارة تستحق الفهم لا الحظر فقط. اشرح الفرق بين الخيال والأذى الحقيقي، '
      'وضع توقعات واضحة، وتحدث مع المدرسة إذا تعلق الأمر بزملاء أو مشاجرات.',
  tips: [
    'Ask what they saw before reacting.',
    'Name the feelings — fear, excitement, curiosity.',
    'Set clear rules about sharing violent material.',
    'Loop in the school if other children are involved.',
  ],
  tipsAr: [
    'اسأل عمّا شاهده قبل أن تتفاعل.',
    'سمِّ المشاعر — الخوف أو الحماس أو الفضول.',
    'ضع قواعد واضحة بشأن مشاركة المواد العنيفة.',
    'أشرك المدرسة إذا كان أطفال آخرون طرفًا في الموضوع.',
  ],
);

const _hateSpeech = CoachCard(
  title: 'When your child encounters hate speech',
  titleAr: 'عندما يصادف طفلك خطاب الكراهية',
  body:
      'Treat slurs and hate memes as a teaching moment, whatever the target. Ask what they think '
      'the words mean and who they hurt, and explain your family\'s values in simple terms. '
      'Children often repeat what earns laughs online — praise them for questioning it, and '
      're-check the communities they spend time in.',
  bodyAr:
      'تعامل مع الشتائم وصور الكراهية الساخرة كفرصة للتعليم أيهما كان الهدف. اسألهم ما معنى هذه '
      'الكلمات وبمن تؤذي، واشرح قيم أسرتك بعبارات بسيطة. كثيرًا ما يكرر الأطفال ما يثير الضحك على '
      'الإنترنت — فامدحهم عندما يشكّون فيه، وأعد النظر في المجموعات التي يقضون فيها وقتهم.',
  tips: [
    'Ask what the words mean to them first.',
    'Explain impact: real people are hurt by "jokes".',
    'State your family values plainly and consistently.',
    'Review the groups and channels they follow.',
  ],
  tipsAr: [
    'اسأل أولًا ما الذي تعنيه هذه الكلمات لهم.',
    'اشرح الأثر: فال«نكات» تؤذي أناسًا حقيقيين.',
    'اذكر قيم أسرتك بوضوح وثبات.',
    'راجع المجموعات والقنوات التي يتابعونها.',
  ],
);

/// Generic social-concern card, used when no specific concernType matched.
const _socialConcern = CoachCard(
  title: 'A worrying message — how to respond',
  titleAr: 'رسالة مقلقة — كيف تتصرف',
  body:
      'Start from curiosity, not accusation. Pick a calm moment, mention what you noticed without '
      'quoting it word for word, and ask open questions: "How do you know this person?" Regular, '
      'short check-ins work better than one big confrontation.',
  bodyAr:
      'ابدأ بالفضول لا الاتهام. اختر لحظة هادئة، واذكر ما لاحظت دون نقله حرفيًا، واسأل أسئلة '
      'مفتوحة: «كيف تعرف هذا الشخص؟» فالاطمئنان القصير المتكرر أنفع من مواجهة كبيرة واحدة.',
  tips: [
    'Choose a calm moment, not the heat of the moment.',
    'Describe what you noticed, not verdicts about their friends.',
    'Ask open questions and let them finish.',
    'Keep checking in regularly — small talks beat big talks.',
  ],
  tipsAr: [
    'اختر لحظة هادئة لا لحظة الغضب.',
    'صِف ما لاحظت لا الأحكام على أصدقائهم.',
    'اسأل أسئلة مفتوحة ودعهم يُكملون كلامهم.',
    'واظب على الاطمئنان باستمرار — فالحوارات الصغيرة أنفع من الكبيرة.',
  ],
);

/// Collaboration framing: limits protect sleep/school/family time, agreed
/// together — never "punishment for too much screen time".
const _screenTime = CoachCard(
  title: 'Agreeing on screen-time limits together',
  titleAr: 'الاتفاق على حدود وقت الشاشة معًا',
  body:
      'Frame limits as collaboration, not punishment: limits protect sleep, homework, and family '
      'time — they are not a verdict on the apps your child loves. Agree on the rules together, '
      'write them down, and model them yourself. When the limit is hit, offer choices ("homework '
      'first, then games?") instead of abrupt shutdowns, and use bonus minutes as encouragement, '
      'not currency.',
  bodyAr:
      'قدّم الحدود كتعاون لا كعقاب: فهي تحمي النوم والواجبات والوقت العائلي — وليست حكمًا على '
      'التطبيقات التي يحبها طفلك. اتفقا على القواعد معًا ودوّنهما، وكن أنت القدوة في تطبيقها. '
      'وعند انتهاء الوقت، قدّم خيارات («الواجب أولًا ثم اللعب؟») بدل الإغلاق المفاجئ، واستخدم '
      'الدقائق الإضافية كتشجيع لا كعملة.',
  tips: [
    'Set limits with your child, not just for them.',
    'Explain the why: sleep, school, mood, family time.',
    'Warn before time is up — abrupt cuts breed conflict.',
    'Model healthy habits with your own screen use.',
    'Review the limits together every few weeks.',
  ],
  tipsAr: [
    'ضع الحدود مع طفلك لا من أجله فقط.',
    'اشرح السبب: النوم والمدرسة والمزاج والوقت العائلي.',
    'نبّه قبل انتهاء الوقت — فالقطع المفاجئ يولّد الخلاف.',
    'كن قدوة في استخدامك أنت لهاتفك.',
    'راجعا الحدود معًا كل بضعة أسابيع.',
  ],
);

const _gamingChat = CoachCard(
  title: 'Staying safe in gaming chats',
  titleAr: 'السلامة في محادثات الألعاب',
  body:
      'Gaming is social — teammates become "friends" fast, and not all of them are children. Talk '
      'about the same rules as everywhere online: no personal details, no moving to private chats '
      'with strangers, and suspicion of anyone offering gifts or cheats. Play together sometimes; '
      'being a fellow player keeps the conversation open.',
  bodyAr:
      'الألعاب مجال اجتماعي — فالزملاء في الفريق يصيرون «أصدقاء» بسرعة، وليسوا جميعًا أطفالًا. '
      'تحدث عن القواعد نفسها المعمول بها على الإنترنت: لا معلومات شخصية، ولا انتقال إلى محادثات '
      'خاصة مع الغرباء، والحذر ممن يعرض هدايا أو «اختراقات». العب معه أحيانًا؛ فكونك زميل لعب '
      'يُبقي الحوار مفتوحًا.',
  tips: [
    'Ask who they play with and how they met.',
    'Agree: no real name, address, school, or photos in chats.',
    'Treat gift-offers and cheat-links as red flags.',
    'Join a game with them now and then.',
  ],
  tipsAr: [
    'اسأل مع من يلعبون وكيف تعرفوا إلى بعضهم.',
    'اتفقا: لا اسم حقيقي ولا عنوان ولا مدرسة ولا صور في المحادثات.',
    'اعتبرا عروض الهدايا وروابط الغش إنذارًا مبكرًا.',
    'شاركه اللعب بين الحين والآخر.',
  ],
);

const _default = CoachCard(
  title: 'A calm first conversation',
  titleAr: 'محادثة أولى هادئة',
  body:
      'Whatever the alert is about, the first conversation sets the tone. Stay calm, be honest '
      'that you are looking out for them, and ask open questions about how they feel and what '
      'happened. The goal is a child who tells you things — not a child who hides them better.',
  bodyAr:
      'مهما كان موضوع التنبيه، فالمحادثة الأولى تحدد النبرة. ابقَ هادئًا، وكن صريحًا في أنك '
      'تحميهم، واسأل أسئلة مفتوحة عن شعورهم وبما حدث. الهدف طفل يُخبرك بما يجري — لا طفل يُخفي '
      'الأمر ببراعة أكبر.',
  tips: [
    'Take a breath before you start — calm is contagious.',
    'Say why you care, not just what the rule is.',
    'Ask open questions: what happened, how do you feel.',
    'End with a plan you agree on together.',
  ],
  tipsAr: [
    'خذ نفسًا عميقًا قبل أن تبدأ — فالهدوء معدٍ.',
    'قل لماذا تهتم، لا القاعدة وحدها.',
    'اسأل أسئلة مفتوحة: ماذا حدث، وكيف تشعر.',
    'اختما بخطة يتفقان عليها معًا.',
  ],
);

/// Alert categories with dedicated cards. `screen_time` is the existing
/// category; `screen_time_exceeded` is the world-class variant — both map to
/// the same collaboration card.
const _categoryCards = <String, CoachCard>{
  'self_harm': _selfHarm,
  'grooming': _grooming,
  'cyberbullying': _cyberbullying,
  'sexual_content': _sexualContent,
  'violence': _violence,
  'hate_speech': _hateSpeech,
  'social_concern': _socialConcern,
  'screen_time': _screenTime,
  'screen_time_exceeded': _screenTime,
  'gaming_chat': _gamingChat,
};

/// Concern-type vocabulary from the AI engine (#2) mapped onto the same cards;
/// unknown types (e.g. late_night) fall through to the generic social card.
const _concernCards = <String, CoachCard>{
  'self_harm': _selfHarm,
  'grooming': _grooming,
  'grooming_risk': _grooming,
  'cyberbullying': _cyberbullying,
  'sexual_content': _sexualContent,
  'explicit_content': _sexualContent,
  'violence': _violence,
  'hate_speech': _hateSpeech,
};

/// Returns the coaching card for [category]; `social_concern` alerts resolve
/// through [concernTypes] first, and anything unknown gets the generic card.
CoachCard coachCardFor(String category, [List<String> concernTypes = const []]) {
  final cat = category.trim().toLowerCase();
  if (cat == 'social_concern') {
    for (final t in concernTypes) {
      final card = _concernCards[t.trim().toLowerCase()];
      if (card != null) return card;
    }
    return _socialConcern;
  }
  return _categoryCards[cat] ?? _default;
}
