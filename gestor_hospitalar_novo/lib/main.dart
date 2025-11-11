import 'dart:io';
import 'package:flutter/material.dart';

// Firebase
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart'; // Gerado pelo FlutterFire CLI

// Outros pacotes
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';

// <-- MUDANÇA: Importação do pacote de máscara
import 'package:mask_text_input_formatter/mask_text_input_formatter.dart';


// --- CONFIGURAÇÃO DO HOSPITAL ---
// IMPORTANTE: Troque estas coordenadas e o raio para os do seu hospital
const double HOSPITAL_LATITUDE = -12.961359; // Exemplo: Hospital da Bahia em Salvador
const double HOSPITAL_LONGITUDE = -38.431027;
const double HOSPITAL_RADIUS_METERS = 500; // O paciente deve estar a no máximo 500 metros
// ---------------------------------


//================================================================================
// INICIALIZAÇÃO
//================================================================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gestor Hospitalar',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF0F2F5),
        inputDecorationTheme: InputDecorationTheme( // Adicionado para um estilo consistente
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          color: Colors.white,
        ),
      ),
      debugShowCheckedModeBanner: false,
      home: const RoleSelectionScreen(),
    );
  }
}

//================================================================================
// TELA 1: SELEÇÃO DE PERFIL (PACIENTE OU GESTÃO)
//================================================================================
class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.local_hospital, size: 80, color: Colors.teal),
              const SizedBox(height: 24),
              const Text(
                'Bem-vindo ao Atendimento Hospitalar',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('Selecione seu perfil para continuar', textAlign: TextAlign.center, style: TextStyle(fontSize: 16, color: Colors.grey)),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                icon: const Icon(Icons.person),
                label: const Text('Sou Paciente'),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const PatientFormScreen())),
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: const Icon(Icons.admin_panel_settings),
                label: const Text('Sou da Gestão'),
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (context) => const AuthWrapper())),
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16), side: const BorderSide(color: Colors.teal)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

//================================================================================
// FLUXO DO PACIENTE
//================================================================================

// TELA 2A: FORMULÁRIO DE CADASTRO DO PACIENTE (COM VERIFICAÇÃO DE LOCALIZAÇÃO)
class PatientFormScreen extends StatefulWidget {
  const PatientFormScreen({super.key});

  @override
  State<PatientFormScreen> createState() => _PatientFormScreenState();
}

class _PatientFormScreenState extends State<PatientFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nomeController = TextEditingController();
  final _cpfController = TextEditingController();
  final _cepController = TextEditingController();

  // <-- MUDANÇA: Criação dos formatadores de máscara
  final _cpfMaskFormatter = MaskTextInputFormatter(mask: '###.###.###-##', filter: {"#": RegExp(r'[0-9]')});
  final _cepMaskFormatter = MaskTextInputFormatter(mask: '#####-###', filter: {"#": RegExp(r'[0-9]')});

  int _prioridade = 3; // 1-Alta, 2-Média, 3-Baixa (Normal)
  String _tipoAtendimento = 'Consulta';
  bool _isLoading = false;
  String _loadingMessage = 'A verificar localização...';

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _emitirSenha() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _loadingMessage = 'A verificar localização...';
    });

    try {
      // 1. VERIFICAR PERMISSÕES E SERVIÇO DE LOCALIZAÇÃO
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showError('Por favor, ative o serviço de localização (GPS).');
        setState(() => _isLoading = false);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          _showError('A permissão de localização é necessária para emitir a senha.');
          setState(() => _isLoading = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        _showError('A permissão de localização foi negada permanentemente. É necessário ativá-la nas configurações.');
        setState(() => _isLoading = false);
        return;
      }

      // 2. OBTER A POSIÇÃO ATUAL DO UTILIZADOR
      Position userPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      // 3. CALCULAR A DISTÂNCIA ATÉ AO HOSPITAL
      double distanceInMeters = Geolocator.distanceBetween(
        userPosition.latitude,
        userPosition.longitude,
        HOSPITAL_LATITUDE,
        HOSPITAL_LONGITUDE,
      );

      // 4. VERIFICAR SE O UTILIZADOR ESTÁ DENTRO DO RAIO PERMITIDO
      if (distanceInMeters > HOSPITAL_RADIUS_METERS) {
        _showError('Você precisa de estar no hospital para retirar uma senha. Distância: ${distanceInMeters.toStringAsFixed(0)} metros.');
        setState(() => _isLoading = false);
        return;
      }

      // 5. SE ESTIVER DENTRO, EMITIR A SENHA NO FIREBASE
      setState(() => _loadingMessage = 'A emitir senha...');
      
      final docRef = await FirebaseFirestore.instance.collection('senhas').add({
        'nomePaciente': _nomeController.text,
        // <-- MUDANÇA: Salva apenas os números (texto sem máscara)
        'cpf': _cpfMaskFormatter.getUnmaskedText(),
        'cep': _cepMaskFormatter.getUnmaskedText(),
        'prioridade': _prioridade,
        'tipoAtendimento': _tipoAtendimento,
        'timestamp': FieldValue.serverTimestamp(),
        'status': 'aguardando',
      });
      
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => PatientTicketScreen(ticketId: docRef.id)));

    } catch (e) {
      _showError('Ocorreu um erro: ${e.toString()}');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dados para Atendimento')),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(_loadingMessage),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(controller: _nomeController, decoration: const InputDecoration(labelText: 'Nome Completo'), validator: (v) => v!.isEmpty ? 'Campo obrigatório' : null),
                    const SizedBox(height: 16),
                    // <-- MUDANÇA: Aplicação da máscara no campo CPF
                    TextFormField(
                      controller: _cpfController, 
                      decoration: const InputDecoration(labelText: 'CPF', hintText: '000.000.000-00'), 
                      keyboardType: TextInputType.number, 
                      inputFormatters: [_cpfMaskFormatter], // Aplica o formatador
                      validator: (v) {
                        if (v == null || v.isEmpty) return 'Campo obrigatório';
                        if (v.length != 14) return 'CPF inválido';
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    // <-- MUDANÇA: Aplicação da máscara no campo CEP
                    TextFormField(
                      controller: _cepController, 
                      decoration: const InputDecoration(labelText: 'CEP (Opcional)', hintText: '00000-000'), 
                      keyboardType: TextInputType.number,
                      inputFormatters: [_cepMaskFormatter], // Aplica o formatador
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _tipoAtendimento,
                      decoration: const InputDecoration(labelText: 'Tipo de Atendimento'),
                      items: ['Consulta', 'Exame', 'Emergência'].map((String value) => DropdownMenuItem<String>(value: value, child: Text(value))).toList(),
                      onChanged: (v) => setState(() => _tipoAtendimento = v!),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      value: _prioridade,
                      decoration: const InputDecoration(labelText: 'Prioridade do Atendimento'),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('Alta (Emergência)')),
                        DropdownMenuItem(value: 2, child: Text('Média (Urgência)')),
                        DropdownMenuItem(value: 3, child: Text('Baixa (Normal)')),
                      ],
                      onChanged: (v) => setState(() => _prioridade = v!),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton(onPressed: _emitirSenha, child: const Text('Emitir Minha Senha')),
                  ],
                ),
              ),
            ),
    );
  }
}

// O RESTANTE DO CÓDIGO CONTINUA IGUAL...

// TELA 3A: TELA DE ESPERA DO PACIENTE
class PatientTicketScreen extends StatelessWidget {
  final String ticketId;
  const PatientTicketScreen({super.key, required this.ticketId});

  Future<void> _desistir(BuildContext context) async {
    await FirebaseFirestore.instance.collection('senhas').doc(ticketId).update({'status': 'cancelado'});
    if (!context.mounted) return;
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const RoleSelectionScreen()), (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('senhas').doc(ticketId).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));

        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Senha não encontrada ou cancelada.'),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () => Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const RoleSelectionScreen()), (route) => false),
                    child: const Text('Voltar ao Início'),
                  ),
                ],
              ),
            ),
          );
        }

        final status = data['status'];
        final senhaLetra = data['tipoAtendimento'][0].toUpperCase();
        final senhaNumero = ticketId.substring(ticketId.length - 3).toUpperCase();

        if (status == 'chamando' || status == 'atendido') {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(status == 'chamando' ? Icons.record_voice_over : Icons.check_circle, size: 80, color: Colors.teal),
                  const SizedBox(height: 24),
                  Text('A sua senha $senhaLetra-$senhaNumero foi chamada!', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Dirija-se ao guichê de atendimento.', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () => Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (context) => const RoleSelectionScreen()), (route) => false),
                    child: const Text('Voltar ao Início'),
                  ),
                ],
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(title: const Text('A Sua Senha'), automaticallyImplyLeading: false),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Aguarde a sua chamada', textAlign: TextAlign.center, style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32.0),
                      child: Text('$senhaLetra-$senhaNumero', textAlign: TextAlign.center, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.bold, color: Colors.teal)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text('Paciente: ${data['nomePaciente']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                  Text('Atendimento: ${data['tipoAtendimento']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.close),
                    label: const Text('Desistir da Senha'),
                    onPressed: () => _desistir(context),
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

//================================================================================
// FLUXO DE GESTÃO
//================================================================================

// "PORTEIRO" DA AUTENTICAÇÃO
class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snapshot.hasData) {
          return const ManagerDashboardScreen();
        }
        return const LoginScreen();
      },
    );
  }
}

// TELA 2B: LOGIN DA GESTÃO
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _login() async {
    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message ?? 'Erro no login')));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login da Gestão')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 40),
                  const Icon(Icons.security, size: 80, color: Colors.teal),
                  const SizedBox(height: 24),
                  TextField(controller: _emailController, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
                  const SizedBox(height: 16),
                  TextField(controller: _passwordController, decoration: const InputDecoration(labelText: 'Senha'), obscureText: true),
                  const SizedBox(height: 24),
                  ElevatedButton(onPressed: _login, child: const Text('Entrar')),
                ],
              ),
            ),
    );
  }
}

// TELA 3B: PAINEL PRINCIPAL DA GESTÃO (SIMPLIFICADO)
class ManagerDashboardScreen extends StatefulWidget {
  const ManagerDashboardScreen({super.key});
  @override
  State<ManagerDashboardScreen> createState() => _ManagerDashboardScreenState();
}

class _ManagerDashboardScreenState extends State<ManagerDashboardScreen> {
  int _currentIndex = 0;
  // A tela de Geolocalização foi removida
  final List<Widget> _screens = [
    const QueueScreen(),
    const BiScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Painel de Gestão'),
        actions: [IconButton(icon: const Icon(Icons.logout), onPressed: () => FirebaseAuth.instance.signOut())],
      ),
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        // O item de Localização foi removido
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.people), label: 'Fila'),
          BottomNavigationBarItem(icon: Icon(Icons.bar_chart), label: 'Dashboard'),
        ],
      ),
    );
  }
}

// TELA 3B.1: FILA DE ATENDIMENTO (GESTÃO)
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  Future<void> _changeStatus(String id, String status) async {
    await FirebaseFirestore.instance.collection('senhas').doc(id).update({'status': status});
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('senhas')
          .where('status', isEqualTo: 'aguardando')
          .orderBy('prioridade')
          .orderBy('timestamp')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('Nenhum paciente na fila.'));

        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final data = docs[index].data() as Map<String, dynamic>;
            final id = docs[index].id;
            final senhaLetra = data['tipoAtendimento'][0].toUpperCase();
            final senhaNumero = id.substring(id.length - 3).toUpperCase();
            
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: data['prioridade'] == 1 ? Colors.red : (data['prioridade'] == 2 ? Colors.orange : Colors.green),
                  child: Text(senhaLetra, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                title: Text('${data['nomePaciente']} ($senhaLetra-$senhaNumero)'),
                subtitle: Text('Chegou às: ${DateFormat('HH:mm').format((data['timestamp'] as Timestamp).toDate())}'),
                trailing: ElevatedButton(
                  onPressed: () => _changeStatus(id, 'chamando'),
                  child: const Text('Chamar'),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

// TELA 3B.2: DASHBOARD (BI)
class BiScreen extends StatelessWidget {
  const BiScreen({super.key});
  
  Future<void> _exportPdf(List<QueryDocumentSnapshot> docs) async {
    final pdf = pw.Document();
    pdf.addPage(pw.Page(build: (pw.Context context) {
      return pw.Table.fromTextArray(
        headers: ['Paciente', 'Tipo', 'Prioridade', 'Data/Hora'],
        data: docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final timestamp = data['timestamp'] as Timestamp?;
          return [
            data['nomePaciente'] ?? '',
            data['tipoAtendimento'] ?? '',
            data['prioridade']?.toString() ?? '',
            timestamp != null ? DateFormat('dd/MM HH:mm').format(timestamp.toDate()) : '',
          ];
        }).toList(),
      );
    }));
    await Printing.layoutPdf(onLayout: (format) async => pdf.save());
  }
  
  Future<void> _exportCsv(List<QueryDocumentSnapshot> docs, BuildContext context) async {
    try {
      List<List<dynamic>> rows = [];
      // Cabeçalho do CSV
      rows.add(['ID da Senha', 'Paciente', 'CPF', 'CEP', 'Tipo de Atendimento', 'Prioridade', 'Data e Hora']);
      
      // Linhas de dados
      for (var doc in docs) {
        final data = doc.data() as Map<String, dynamic>;
        rows.add([
          doc.id,
          data['nomePaciente'] ?? '',
          data['cpf'] ?? '',
          data['cep'] ?? '',
          data['tipoAtendimento'] ?? '',
          data['prioridade']?.toString() ?? '',
          DateFormat('yyyy-MM-dd HH:mm:ss').format((data['timestamp'] as Timestamp).toDate()),
        ]);
      }

      // Converte a lista de listas para uma string formatada como CSV
      String csv = const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
      
      // Converte a string para bytes para poder ser guardada
      final Uint8List bytes = utf8.encode(csv);
      
      // Usa o file_saver para descarregar o ficheiro. Funciona na Web, Desktop e Mobile!
      String dataFormatada = DateFormat('yyyy-MM-dd_HH-mm').format(DateTime.now());
      await FileSaver.instance.saveFile(
        name: 'relatorio_senhas_$dataFormatada',
        bytes: bytes,
        ext: 'csv',
        mimeType: MimeType.csv,
      );

    } catch (e) {
      // Mostra uma mensagem de erro se algo correr mal
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao exportar CSV: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
       stream: FirebaseFirestore.instance.collection('senhas').orderBy('timestamp', descending: true).snapshots(),
       builder: (context, snapshot) {
         if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
         final docs = snapshot.data!.docs;

         // Lógica para contagem
         int total = docs.length;
         int alta = docs.where((d) => (d.data() as Map)['prioridade'] == 1).length;
         int media = docs.where((d) => (d.data() as Map)['prioridade'] == 2).length;
         int baixa = docs.where((d) => (d.data() as Map)['prioridade'] == 3).length;

         return ListView(
           padding: const EdgeInsets.all(16),
           children: [
             Text('Métricas Gerais', style: Theme.of(context).textTheme.headlineSmall),
             const SizedBox(height: 16),
             Wrap(
               spacing: 16,
               runSpacing: 16,
               children: [
                 MetricCard(title: 'Total de Senhas', value: total.toString()),
                 MetricCard(title: 'Prioridade Alta', value: alta.toString()),
                 MetricCard(title: 'Prioridade Média', value: media.toString()),
                 MetricCard(title: 'Prioridade Baixa', value: baixa.toString()),
               ],
             ),
             const SizedBox(height: 24),
             Text('Relatórios', style: Theme.of(context).textTheme.headlineSmall),
             const SizedBox(height: 16),
             ElevatedButton.icon(icon: const Icon(Icons.picture_as_pdf), label: const Text('Exportar para PDF'), onPressed: () => _exportPdf(docs)),
             const SizedBox(height: 10),
             // Chamada da função corrigida
             ElevatedButton.icon(icon: const Icon(Icons.table_chart), label: const Text('Exportar para CSV (Excel)'), onPressed: () => _exportCsv(docs, context)),
           ],
         );
       },
    );
  }
}

class MetricCard extends StatelessWidget {
  final String title;
  final String value;
  const MetricCard({super.key, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Container(
        padding: const EdgeInsets.all(16),
        width: 150,
        child: Column(
          children: [
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            Text(title),
          ],
        ),
      ),
    );
  }
}