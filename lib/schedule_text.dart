/// 调度文案工具：把 cron 表达式 / 间隔描述翻译成人话，
/// 以及把下次运行时间转成相对倒计时。纯函数，便于单测。

/// 把 schedule_display（cron 表达式 / "every 30m" / "30m" / ISO 时间）转成中文描述。
/// 无法识别时原样返回。
String describeSchedule(String? display) {
  if (display == null || display.trim().isEmpty) return '-';
  final s = display.trim();

  // 间隔：every 30m / every 2h / every 1d
  final every = RegExp(r'^every\s+(\d+)\s*([mhd])$', caseSensitive: false)
      .firstMatch(s);
  if (every != null) {
    final n = every.group(1)!;
    return '每 $n ${_unitName(every.group(2)!)}';
  }

  // 一次性相对时长：30m / 2h / 1d
  final once = RegExp(r'^(\d+)\s*([mhd])$').firstMatch(s);
  if (once != null) {
    return '一次性（${once.group(1)} ${_unitName(once.group(2)!)}后）';
  }

  // ISO-8601 一次性时间
  if (DateTime.tryParse(s) != null && s.contains('T')) {
    return '一次性定时';
  }

  // cron 5 段
  final fields = s.split(RegExp(r'\s+'));
  if (fields.length == 5) {
    return _describeCron(fields[0], fields[1], fields[2], fields[3], fields[4]);
  }
  return s;
}

String _unitName(String unit) {
  switch (unit.toLowerCase()) {
    case 'm':
      return '分钟';
    case 'h':
      return '小时';
    case 'd':
      return '天';
    default:
      return unit;
  }
}

String _describeCron(String min, String hour, String dom, String mon, String dow) {
  // 每分钟
  if (min == '*' && hour == '*' && dom == '*' && mon == '*' && dow == '*') {
    return '每分钟';
  }
  // 每 n 分钟
  final everyMin = RegExp(r'^\*/(\d+)$').firstMatch(min);
  if (everyMin != null && hour == '*' && dom == '*' && mon == '*' && dow == '*') {
    return '每 ${everyMin.group(1)} 分钟';
  }
  // 每小时第 m 分
  if (_isNum(min) && hour == '*' && dom == '*' && mon == '*' && dow == '*') {
    return '每小时第 $min 分';
  }
  // 每 n 小时
  final everyHour = RegExp(r'^\*/(\d+)$').firstMatch(hour);
  if (_isNum(min) && everyHour != null && dom == '*' && mon == '*' && dow == '*') {
    return '每 ${everyHour.group(1)} 小时';
  }
  if (_isNum(min) && _isNum(hour) && mon == '*') {
    final time = '${hour.padLeft(2, '0')}:${min.padLeft(2, '0')}';
    // 每天
    if (dom == '*' && dow == '*') return '每天 $time';
    // 工作日
    if (dom == '*' && (dow == '1-5')) return '工作日 $time';
    // 每周某天
    if (dom == '*' && _isNum(dow)) return '每周${_weekName(int.parse(dow))} $time';
    // 每月某日
    if (_isNum(dom) && dow == '*') return '每月 $dom 日 $time';
  }
  return '$min $hour $dom $mon $dow';
}

bool _isNum(String s) => RegExp(r'^\d{1,2}$').hasMatch(s);

String _weekName(int dow) {
  const names = ['日', '一', '二', '三', '四', '五', '六'];
  return names[dow % 7];
}

/// 下次运行的相对倒计时，如 "25 分钟后" / "3 小时后" / "2 天后" / "已过期"。
String relativeCountdown(String? iso, {DateTime? now}) {
  if (iso == null || iso.isEmpty) return '-';
  final dt = DateTime.tryParse(iso);
  if (dt == null) return '-';
  final ref = now ?? DateTime.now();
  var diff = dt.toLocal().difference(ref);
  if (diff.isNegative) return '已过期';
  if (diff.inMinutes < 1) return '即将';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟后';
  if (diff.inHours < 24) {
    final h = diff.inHours;
    final m = diff.inMinutes - h * 60;
    return m == 0 ? '$h 小时后' : '$h 小时 $m 分后';
  }
  final d = diff.inDays;
  return d >= 1 ? '$d 天后' : '1 天后';
}
