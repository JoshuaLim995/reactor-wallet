import 'package:solana/dto.dart' show ProgramAccount;
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart'
    show
        Ed25519HDKeyPair,
        Ed25519HDPublicKey,
        RpcClientExt,
        SolanaClient,
        SolanaClientAssociatedTokenAccontProgram,
        SystemInstruction,
        TokenInstruction,
        TokenProgram,
        Wallet,
        lamportsPerSol;
import 'package:reactor_wallet/components/network_selector.dart';
import 'package:reactor_wallet/utils/tracker.dart';
import 'package:worker_manager/worker_manager.dart';
import 'package:bip39/bip39.dart' as bip39;
import 'base_account.dart';

class WalletAccount extends BaseAccount implements Account {
  @override
  final AccountType accountType = AccountType.Wallet;

  late Wallet wallet;
  final String mnemonic;

  WalletAccount(
    double balance,
    name,
    NetworkUrl url,
    this.mnemonic,
    tokensTracker,
  ) : super(balance, name, url, tokensTracker) {
    client = SolanaClient(
      rpcUrl: Uri.parse(url.rpc),
      websocketUrl: Uri.parse(url.ws),
    );
  }

  /*
   * Constructor in case the address is already known
   */
  WalletAccount.withAddress(
    double balance,
    String address,
    name,
    NetworkUrl url,
    this.mnemonic,
    tokensTracker,
  ) : super(balance, name, url, tokensTracker) {
    this.address = address;
    client = SolanaClient(
      rpcUrl: Uri.parse(url.rpc),
      websocketUrl: Uri.parse(url.ws),
    );
  }

  /*
   * Send SOLs to an adress
   */
  Future<String> sendLamportsTo(
    String fundingAccount,
    String recipientAccount,
    int amount, {
    List<String> references = const [],
  }) async {
    final instruction = SystemInstruction.transfer(
      lamports: amount,
      fundingAccount: Ed25519HDPublicKey.fromBase58(fundingAccount),
      recipientAccount: Ed25519HDPublicKey.fromBase58(recipientAccount),
    );

    for (final reference in references) {
      instruction.accounts.add(
        AccountMeta(
          pubKey: Ed25519HDPublicKey.fromBase58(reference),
          isWriteable: false,
          isSigner: false,
        ),
      );
    }

    final message = Message(
      instructions: [instruction],
    );

    final signature =
        await client.rpcClient.signAndSendTransaction(message, [wallet]);

    return signature;
  }

  /*
   * Send a Token to an adress
   */
  Future<String> sendSPLTokenTo(
    String destinationAddress,
    String tokenMint,
    int amount, {
    List<String> references = const [],
  }) async {
    final associatedRecipientAccount = await client.getAssociatedTokenAccount(
      owner: Ed25519HDPublicKey.fromBase58(destinationAddress),
      mint: Ed25519HDPublicKey.fromBase58(tokenMint),
    );

    final associatedSenderAccount = await client.getAssociatedTokenAccount(
      owner: Ed25519HDPublicKey.fromBase58(address),
      mint: Ed25519HDPublicKey.fromBase58(tokenMint),
    ) as ProgramAccount;

    final instructions = TokenInstruction.transfer(
      source: Ed25519HDPublicKey.fromBase58(associatedSenderAccount.pubkey),
      destination:
          Ed25519HDPublicKey.fromBase58(associatedRecipientAccount!.pubkey),
      amount: amount,
      owner: Ed25519HDPublicKey.fromBase58(address),
    );

    for (final reference in references) {
      instructions.accounts.add(
        AccountMeta(
          pubKey: Ed25519HDPublicKey.fromBase58(reference),
          isWriteable: false,
          isSigner: false,
        ),
      );
    }

    final signature = await client.rpcClient.signAndSendTransaction(
        Message(instructions: [instructions]), [wallet]);

    return signature;
  }

  Future<String> sendTransaction(Transaction transaction) {
    if (transaction.token is SOL) {
      // Convert SOL to lamport
      int lamports = (transaction.ammount * lamportsPerSol).toInt();

      return sendLamportsTo(
        transaction.origin,
        transaction.destination,
        lamports,
        references: transaction.references,
      );
    } else {
      // Input by the user
      int userAmount = transaction.ammount.toInt();
      // Token's configured decimals
      int tokenDecimals = transaction.token.info.decimals;
      int amount = int.parse('$userAmount${'0' * tokenDecimals}');

      return sendSPLTokenTo(
        transaction.destination,
        transaction.token.mint,
        amount,
        references: transaction.references,
      );
    }
  }

  /*
   * Create the keys pair in Isolate to prevent blocking the main thread
   */
  static Future<Ed25519HDKeyPair> createKeyPair(String mnemonic) async {
    final Ed25519HDKeyPair keyPair =
        await Ed25519HDKeyPair.fromMnemonic(mnemonic);
    return keyPair;
  }

  /*
   * Load the keys pair into the WalletAccount
   */
  Future<void> loadKeyPair() async {
    final Ed25519HDKeyPair keyPair = await Executor().execute(
      arg1: mnemonic,
      fun1: createKeyPair,
    );
    wallet = keyPair;
    address = wallet.address;
  }

  /*
   * Create a WalletAccount with a random mnemonic
   */
  static Future<WalletAccount> generate(
      String name, NetworkUrl url, tokensTracker) async {
    final String randomMnemonic = bip39.generateMnemonic();

    WalletAccount account = WalletAccount(
      0,
      name,
      url,
      randomMnemonic,
      tokensTracker,
    );
    await account.loadKeyPair();
    await account.refreshBalance();
    return account;
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "name": name,
      "address": address,
      "balance": balance,
      "url": [url.rpc, url.ws],
      "mnemonic": mnemonic,
      "accountType": accountType.toString(),
      "transactions": transactions.map((tx) => tx.toJson()).toList()
    };
  }
}
