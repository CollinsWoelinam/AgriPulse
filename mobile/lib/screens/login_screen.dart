import 'package:flutter/material.dart';

import '../api.dart';
import '../services.dart';
import '../ui/theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final _server = TextEditingController();
  bool _busy = false;
  bool _showServer = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_server.text.isEmpty) _server.text = ServicesScope.of(context).serverUrl;
  }

  Future<void> _submit() async {
    setState(() { _busy = true; _error = null; });
    try {
      await ServicesScope.of(context).signIn(_server.text.trim(), _email.text.trim(), _password.text);
    } on ApiException catch (e) {
      setState(() => _error = e.status == 401 ? 'Wrong email or password.' : e.message);
    } on Exception {
      setState(() => _error = "Can't reach the server. Check the address and your connection.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(_server.text)?.authority ?? _server.text;
    return Scaffold(
      backgroundColor: AP.ink,
      resizeToAvoidBottomInset: true,
      body: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: box.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Hero
                  SizedBox(
                    height: 330,
                    child: Stack(children: [
                      Positioned(
                        right: -100,
                        top: 60,
                        child: Transform.rotate(
                          angle: -0.17,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: const NdviMosaic(size: 240),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 28,
                        right: 28,
                        bottom: 28,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(color: AP.lime, borderRadius: BorderRadius.circular(14)),
                            child: const Icon(Icons.monitor_heart_outlined, color: AP.ink, size: 26),
                          ),
                          const SizedBox(height: 14),
                          const Text('AgriPulse', style: TextStyle(color: Colors.white, fontSize: 32, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                          const Text('Scout', style: TextStyle(color: AP.lime, fontSize: 32, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                          const SizedBox(height: 10),
                          // Narrow enough to stay clear of the mosaic on the right.
                          const SizedBox(
                            width: 200,
                            child: Text('Find and record crop stress in the field, even with no signal.',
                                style: TextStyle(color: AP.onDark, fontSize: 15, height: 1.45)),
                          ),
                        ]),
                      ),
                    ]),
                  ),
                  // Form sheet
                  Expanded(
                    child: Container(
                      decoration: const BoxDecoration(color: AP.bg, borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
                      padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                      child: SafeArea(
                        top: false,
                        child: AutofillGroup(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            const _Label('Email'),
                            TextField(
                              key: const Key('email'),
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              autofillHints: const [AutofillHints.username],
                              style: const TextStyle(fontSize: 16),
                            ),
                            const SizedBox(height: 16),
                            const _Label('Password'),
                            TextField(
                              key: const Key('password'),
                              controller: _password,
                              obscureText: true,
                              autofillHints: const [AutofillHints.password],
                              onSubmitted: (_) => _submit(),
                              style: const TextStyle(fontSize: 16),
                            ),
                            const SizedBox(height: 4),
                            TextButton(
                              onPressed: () => setState(() => _showServer = !_showServer),
                              style: TextButton.styleFrom(foregroundColor: AP.ink2, padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 48)),
                              child: Row(children: [
                                const Icon(Icons.dns_outlined, size: 18),
                                const SizedBox(width: 8),
                                const Text('Server ', style: TextStyle(fontSize: 14)),
                                Expanded(child: Text(host, style: AP.monoStyle(13, color: AP.muted, weight: FontWeight.w400), overflow: TextOverflow.ellipsis)),
                                Icon(_showServer ? Icons.expand_less : Icons.expand_more, size: 20),
                              ]),
                            ),
                            if (_showServer)
                              TextField(
                                key: const Key('server'),
                                controller: _server,
                                keyboardType: TextInputType.url,
                                onChanged: (_) => setState(() {}),
                                style: AP.monoStyle(14, weight: FontWeight.w400),
                              ),
                            if (_error != null) ...[
                              const SizedBox(height: 10),
                              Text(_error!, style: const TextStyle(color: AP.alert, fontWeight: FontWeight.w600)),
                            ],
                            const Spacer(),
                            const SizedBox(height: 20),
                            FilledButton(
                              key: const Key('sign-in'),
                              onPressed: _busy ? null : _submit,
                              child: _busy
                                  ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                                  : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                      Text('Sign in'),
                                      SizedBox(width: 10),
                                      Icon(Icons.arrow_forward, color: AP.lime, size: 20),
                                    ]),
                            ),
                            const SizedBox(height: 12),
                            const Text('Accounts are created by your farm manager.',
                                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AP.muted)),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      );
}
