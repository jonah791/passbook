import 'package:flutter/material.dart';
import 'package:kpasslib/kpasslib.dart';

import '../main.dart' show vault;

class EditorPage extends StatefulWidget {
  const EditorPage({super.key, required this.entry});

  final KdbxEntry entry;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final TextEditingController _title;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _url;
  late final TextEditingController _notes;
  bool _reveal = false;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    _title = TextEditingController(text: vault.fieldOf(entry, 'Title'));
    _username = TextEditingController(text: vault.fieldOf(entry, 'UserName'));
    _password = TextEditingController(text: vault.fieldOf(entry, 'Password'));
    _url = TextEditingController(text: vault.fieldOf(entry, 'URL'));
    _notes = TextEditingController(text: vault.fieldOf(entry, 'Notes'));
  }

  @override
  void dispose() {
    _title.dispose();
    _username.dispose();
    _password.dispose();
    _url.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    vault.updateEntry(widget.entry, {
      'Title': _title.text,
      'UserName': _username.text,
      'Password': _password.text,
      'URL': _url.text,
      'Notes': _notes.text,
    });
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑条目'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: !_reveal,
            decoration: InputDecoration(
              labelText: '密码',
              suffixIcon: IconButton(
                icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _reveal = !_reveal),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(labelText: '网址'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            maxLines: 6,
            decoration: const InputDecoration(labelText: '备注'),
          ),
        ],
      ),
    );
  }
}
