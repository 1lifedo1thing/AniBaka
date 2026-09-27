import 'dart:collection';

/// Literal multi-pattern matching. Build once when words change; queries walk
/// the text once using Aho–Corasick failure links, without allocating substrings.
final class SubstringMatcher {
  SubstringMatcher(List<String> words)
    : _small = words.length <= 8 ? words : null {
    if (_small != null) return;
    for (final word in words) {
      var state = 0;
      for (var i = 0; i < word.length; i++) {
        final unit = word.codeUnitAt(i);
        var next = _nodes[state].edges[unit];
        if (next == null) {
          next = _nodes.length;
          _nodes[state].edges[unit] = next;
          _nodes.add(_Node());
        }
        state = next;
      }
      _nodes[state].matches = true;
    }
    final queue = Queue<int>()..addAll(_nodes[0].edges.values);
    while (queue.isNotEmpty) {
      final state = queue.removeFirst();
      for (final edge in _nodes[state].edges.entries) {
        var fallback = _nodes[state].failure;
        while (fallback != 0 && !_nodes[fallback].edges.containsKey(edge.key)) {
          fallback = _nodes[fallback].failure;
        }
        final node = _nodes[edge.value];
        node.failure = _nodes[fallback].edges[edge.key] ?? 0;
        node.matches = node.matches || _nodes[node.failure].matches;
        queue.add(edge.value);
      }
    }
  }

  final List<String>? _small;
  final _nodes = <_Node>[_Node()];

  bool matches(String text) {
    final small = _small;
    if (small != null) {
      for (var i = 0; i < small.length; i++) {
        if (text.contains(small[i])) return true;
      }
      return false;
    }
    if (_nodes[0].matches) return true;
    var state = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      var next = _nodes[state].edges[unit];
      while (next == null && state != 0) {
        state = _nodes[state].failure;
        next = _nodes[state].edges[unit];
      }
      state = next ?? 0;
      if (_nodes[state].matches) return true;
    }
    return false;
  }
}

final class _Node {
  final edges = <int, int>{};
  int failure = 0;
  bool matches = false;
}
