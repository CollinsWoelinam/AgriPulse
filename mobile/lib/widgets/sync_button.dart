import 'package:flutter/material.dart';

import '../services.dart';

/// App-bar sync status: shows how many uploads are waiting; tap to sync now and see details.
class SyncButton extends StatelessWidget {
  const SyncButton({super.key});

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);
    final sync = services.sync;
    if (sync == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final icon = sync.syncing
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(sync.lastError != null && sync.pending > 0 ? Icons.cloud_off : sync.pending > 0 ? Icons.cloud_upload : Icons.cloud_done);
        return IconButton(
          key: const Key('sync'),
          tooltip: sync.pending == 0 ? 'Everything uploaded' : '${sync.pending} waiting to upload',
          icon: Badge(isLabelVisible: sync.pending > 0, label: Text('${sync.pending}'), child: icon),
          onPressed: () async {
            if (sync.authExpired) {
              await services.signOut();
              return;
            }
            await sync.syncNow();
            if (!context.mounted) return;
            final text = sync.pending == 0
                ? 'All observations uploaded.'
                : '${sync.pending} item(s) waiting. ${sync.lastError ?? ''}';
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
          },
        );
      },
    );
  }
}
