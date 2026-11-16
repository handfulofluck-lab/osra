List<String> splitLocalizedList(String input,
    {bool stripDirectionMarks = false}) {
  final text = stripDirectionMarks
      ? input.replaceAll(RegExp(r'[\u200E\u200F\u061C]'), '')
      : input;
  return text
      .split(RegExp(r'[,;\u060C\u061B\r\n]+'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}
