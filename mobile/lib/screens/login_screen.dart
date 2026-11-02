import 'package:flutter/material.dart';

import '../api.dart';
import '../services.dart';

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
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.eco, size: 48, color: theme.colorScheme.primary),
                    const SizedBox(height: 8),
                    Text('AgriPulse Scout', textAlign: TextAlign.center, style: theme.textTheme.headlineSmall),
                    Text('Find and record crop stress in the field',
                        textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 32),
                    TextField(
                      key: const Key('email'),
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('password'),
                      controller: _password,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    ExpansionTile(
                      title: const Text('Server'),
                      tilePadding: EdgeInsets.zero,
                      children: [
                        TextField(
                          key: const Key('server'),
                          controller: _server,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(border: OutlineInputBorder()),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      key: const Key('sign-in'),
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : const Text('Sign in'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
