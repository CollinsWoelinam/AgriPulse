import 'package:flutter/material.dart';

import '../services.dart';
import '../ui/theme.dart';

/// Sync status pill: "Synced", "N waiting" or "Offline". Tap to sync now.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key, this.onDark = false});

  final bool onDark; // floating over the map

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    final sync = services.sync;
    if (sync == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final offline = sync.lastError != null && sync.pending > 0;
        final (icon, label, color) = sync.pending == 0
            ? (Icons.cloud_done_outlined, 'Synced', AP.forest)
            : offline
                ? (Icons.cloud_off, 'Offline · ${sync.pending}', const Color(0xFF9A6400))
                : (Icons.cloud_upload_outlined, '${sync.pending} waiting', const Color(0xFF9A6400));
        return Semantics(
          button: true,
          label: sync.pending == 0 ? 'Everything uploaded' : '${sync.pending} waiting to upload. Tap to sync now',
          child: Material(
            color: Colors.white,
            shape: StadiumBorder(side: BorderSide(color: onDark ? Colors.transparent : AP.line2)),
            elevation: onDark ? 4 : 0,
            child: InkWell(
              key: const Key('sync'),
              customBorder: const StadiumBorder(),
              onTap: () async {
                if (sync.authExpired) {
                  await services.signOut();
                  return;
                }
                await sync.syncNow();
                if (!context.mounted) return;
                final text = sync.pending == 0 ? 'All observations uploaded.' : '${sync.pending} item(s) waiting. ${sync.lastError ?? ''}';
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
              },
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (sync.syncing)
                    SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: color))
                  else
                    Icon(icon, size: 18, color: color),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}
