import 'package:flutter/material.dart';
import '../models/types.dart';
import '../theme.dart';

/// The right-side live reasoning panel. Each agent step is a collapsible card
/// with its reasoning + tool calls.
class TracePanel extends StatelessWidget {
  final List<TraceStep> steps;
  final bool isRunning;

  const TracePanel({super.key, required this.steps, required this.isRunning});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            child: Row(
              children: [
                if (isRunning)
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                else
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: steps.isEmpty ? Colors.white24 : AppColors.intent,
                      shape: BoxShape.circle,
                    ),
                  ),
                const SizedBox(width: 8),
                Text(
                  'AGENT TRACE',
                  style: AppFonts.mono(size: 10, color: Colors.white60).copyWith(
                    letterSpacing: 1.4,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text('${steps.length}',
                    style: AppFonts.mono(size: 10, color: Colors.white38)),
              ],
            ),
          ),
          Expanded(
            child: steps.isEmpty
                ? _emptyState()
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: steps.length,
                    itemBuilder: (_, i) => _TraceCard(step: steps[i], index: i + 1),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_outlined, color: Colors.white24, size: 28),
            const SizedBox(height: 8),
            Text(
              'Send a message to see\nthe agents think',
              textAlign: TextAlign.center,
              style: AppFonts.base(size: 12, color: Colors.white38),
            ),
          ],
        ),
      ),
    );
  }
}

class _TraceCard extends StatefulWidget {
  final TraceStep step;
  final int index;
  const _TraceCard({required this.step, required this.index});

  @override
  State<_TraceCard> createState() => _TraceCardState();
}

class _TraceCardState extends State<_TraceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final accent = accentForAgent(widget.step.agent);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: accent.withOpacity(0.06),
        border: Border.all(color: accent.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.only(right: 8, top: 1),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${widget.index}',
                      style: AppFonts.mono(size: 10, color: accent),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.step.agent.toUpperCase(),
                          style: AppFonts.mono(size: 10, color: accent).copyWith(
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _shortReasoning(widget.step.reasoning, widget.step.output),
                          maxLines: _expanded ? null : 3,
                          overflow:
                              _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                          style: AppFonts.base(size: 12, color: Colors.white.withOpacity(0.85)),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '${(widget.step.ms / 1000).toStringAsFixed(1)}s',
                    style: AppFonts.mono(size: 9, color: Colors.white38),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded && widget.step.toolsCalled.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(40, 0, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.step.toolsCalled
                    .map((tc) => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.bolt, size: 10, color: accent.withOpacity(0.7)),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  '${tc.name} · ${tc.ms}ms',
                                  style: AppFonts.mono(size: 10, color: Colors.white60),
                                ),
                              ),
                            ],
                          ),
                        ))
                    .toList(),
              ),
            ),
        ],
      ),
    );
  }

  String _shortReasoning(String raw, dynamic output) {
    // Strip complete fenced blocks AND any leading partial fence,
    // and any leading raw JSON object.
    String stripped = raw
        .replaceAll(RegExp(r'```[a-z]*\n[\s\S]*?\n```'), '')
        .replaceAll(RegExp(r'```[a-z]*[\s\S]*$', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\{[\s\S]*\}\s*$'), '')
        .trim();
    // If what's left starts with `{` we still have JSON garbage — fall through.
    if (stripped.isNotEmpty && !stripped.startsWith('{') && !stripped.startsWith('```')) {
      return stripped.length > 280 ? '${stripped.substring(0, 280)}…' : stripped;
    }
    // Fallback 1: agent-output's own reasoning field
    if (output is Map) {
      final r = output['reasoning'];
      if (r is String && r.isNotEmpty) {
        return r.length > 280 ? '${r.substring(0, 280)}…' : r;
      }
      // Fallback 2: derive a short summary from the structured output
      final s = _summarizeOutput(widget.step.agent, output);
      if (s.isNotEmpty) return s;
    }
    return _agentDefaultMessage(widget.step.agent);
  }

  String _summarizeOutput(String agent, Map output) {
    switch (agent) {
      case 'intent':
        final cat = (output['service'] as Map?)?['category_id'];
        final loc = (output['location'] as Map?)?['label'];
        final time = (output['time'] as Map?)?['user_phrase'] ??
            (output['time'] as Map?)?['iso'];
        final lang = output['language'];
        final urg = output['urgency'];
        final parts = [
          if (cat != null) 'service: $cat',
          if (loc != null) 'location: $loc',
          if (time != null) 'time: $time',
          if (urg != null) 'urgency: $urg',
          if (lang != null) 'lang: $lang',
        ];
        return parts.join(' · ');
      case 'discovery':
        final c = output['candidates'] as List?;
        final strategy = output['search_strategy'];
        return '${c?.length ?? 0} candidates found' +
            (strategy is String && strategy.isNotEmpty ? ' — $strategy' : '');
      case 'ranking':
        final mode = output['recommendation_mode'];
        final top = (output['top_3'] as List?)?.cast<Map?>().firstOrNull;
        if (top != null) {
          final name = top['provider_id'] ?? top['rank'];
          final why = top['reasoning'];
          return 'Top pick: $name${why is String && why.isNotEmpty ? " — $why" : ""} (mode: $mode)';
        }
        return 'mode: $mode';
      case 'booking':
        final id = output['booking_id'];
        final status = output['status'];
        final reason = output['reasoning'];
        if (id != null) return 'Booking $id · $status';
        if (reason is String && reason.isNotEmpty) return reason;
        return 'status: $status';
      case 'followup':
        final jobs = output['scheduled_jobs'] as List?;
        return '${jobs?.length ?? 0} follow-ups scheduled';
      default:
        return '';
    }
  }

  String _agentDefaultMessage(String agent) {
    switch (agent) {
      case 'intent':
        return 'Parsed user request…';
      case 'discovery':
        return 'Searched provider pool…';
      case 'ranking':
        return 'Ranked candidates by user preferences…';
      case 'booking':
        return 'Booking written…';
      case 'followup':
        return 'Follow-ups scheduled…';
      default:
        return 'Agent completed.';
    }
  }
}
