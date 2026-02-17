import 'local_kokoro_voice_bank.dart';

final _bank = LocalKokoroVoiceBank();

Future<List<String>> loadLocalVoiceIdsImpl() => _bank.listVoiceIds();
