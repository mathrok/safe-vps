# Manual de instalação

Do servidor recém-comprado até o servidor protegido, passo a passo. Leva uns
30 minutos. O que cada mudança faz e por quê está no [README](README.md).

---

## Antes de começar

Você vai precisar de:

- **Uma VPS com Ubuntu 24.04** (de qualquer provedor). Na hora de criar, escolha
  "Ubuntu 24.04" como sistema. O script foi feito e testado nessa versão.
- **O endereço IP do servidor** (o provedor mostra no painel, algo como
  `203.0.113.10`). Neste manual ele aparece como `IP-DO-SERVIDOR`.
- **Acesso ao "console" do provedor.** Quase todo provedor tem, no painel, um
  botão como "Console", "Terminal web" ou "VNC", que abre o servidor direto no
  navegador. É a sua porta dos fundos se algo der errado com o SSH. Ache esse
  botão antes de começar, só para saber onde fica.
- **Um gerenciador de senhas** (Bitwarden, 1Password, KeePass...) para guardar a
  senha que você vai criar.

> **Dica:** faça isso pela primeira vez num servidor novo e vazio. Se algo der
> errado, você apaga e cria outro em minutos.

---

## Passo 1. Criar a sua chave SSH (no seu computador)

A chave SSH é um par de arquivos:

- a **chave privada** (`id_ed25519`) fica SÓ no seu computador. Nunca envie
  para ninguém, nunca cole em lugar nenhum;
- a **chave pública** (`id_ed25519.pub`) é a que vai para o servidor. Pode ser
  mostrada sem medo.

### Windows 10 ou 11

1. Abra o menu Iniciar, digite **PowerShell** e abra.
2. Digite e aperte Enter:
   ```
   ssh-keygen -t ed25519
   ```
3. Ele pergunta onde salvar: aperte **Enter** (aceita o lugar padrão).
4. Ele pede uma "passphrase": é uma senha para proteger a chave no seu
   computador. Recomendado: crie uma e guarde no gerenciador de senhas. (Ao
   digitar, nada aparece na tela; é normal.)
5. Para ver a chave pública, digite:
   ```
   type $env:USERPROFILE\.ssh\id_ed25519.pub
   ```
   Aparece uma linha começando com `ssh-ed25519 AAAA...`. Deixe essa janela
   aberta: você vai copiar essa linha no passo 4.

### Mac ou Linux

1. Abra o **Terminal**.
2. Digite `ssh-keygen -t ed25519` e responda como no Windows (Enter, depois a
   passphrase).
3. Para ver a chave pública: `cat ~/.ssh/id_ed25519.pub`

> Se você **já tem** uma chave (o arquivo já existe), não crie outra. Use a que
> já tem.

> Muitos provedores deixam colar a chave pública na hora de criar o servidor.
> Se você fez isso, ótimo: o script copia essa chave para a sua conta nova
> automaticamente.

---

## Passo 2. Entrar no servidor pela primeira vez

No PowerShell (ou Terminal), digite:

```
ssh root@IP-DO-SERVIDOR
```

- Na primeira vez aparece "Are you sure you want to continue connecting?".
  Digite `yes` e Enter.
- Se o provedor te deu uma senha de root, ele pede agora.
- Alguns provedores (AWS, Oracle, Google) não usam root e sim um usuário como
  `ubuntu`. Nesse caso: `ssh ubuntu@IP-DO-SERVIDOR`, e nos próximos passos use
  `sudo` na frente dos comandos.

Quando aparecer algo como `root@nome-do-servidor:~#`, você está dentro.

---

## Passo 3. Baixar o script

Ainda dentro do servidor, digite:

```
git clone https://github.com/mathrok/safe-vps.git
cd safe-vps
```

(Se aparecer "git: command not found", rode antes `apt update && apt install -y git`.)

> **Boa prática:** leia o que um script faz antes de rodá-lo como
> administrador. Para ler este: `less safe-vps.sh` (`q` para sair).

---

## Passo 4. Rodar o script

```
sudo bash safe-vps.sh
```

O script trabalha em três partes:

### Parte A: perguntas

Ele faz 12 perguntas, uma de cada vez. Cada uma explica o que é e já traz
uma **sugestão entre colchetes**, assim: `Fuso horário [America/Sao_Paulo]:`.

- Aperte **Enter** para aceitar a sugestão.
- Ou digite outro valor e aperte Enter.
- Se a resposta não servir, ele explica por quê e pergunta de novo.

Na pergunta da **chave SSH**, cole a linha `ssh-ed25519 AAAA...` do passo 1.
Para colar no PowerShell: clique com o botão **direito** do mouse. No Mac:
Cmd+V. Se a chave já foi colocada pelo provedor, pode só apertar Enter.

Nada é mudado durante as perguntas. No fim ele mostra um resumo e pergunta
"Está tudo certo?".

### Parte B: conferência

Ele olha o servidor e mostra, linha por linha:

- `[ok]` o que já está certo;
- `[falta]` o que ele vai mudar;
- `[atenção]` algo que você deve saber, mas que ele não muda sozinho.

Leia com calma. Depois ele pergunta **"Posso aplicar essas mudanças agora?"**.
Só digite `sim` se estiver de acordo. Qualquer outra resposta não muda nada.

### Parte C: aplicação

- Ele instala os programas e muda as configurações. Leva de 2 a 10 minutos.
- Se a sua conta ainda não tiver senha, ele pede para você **criar a senha
  do sudo**. Ela é pedida quando você for administrar o servidor. Ao digitar,
  nada aparece na tela; é normal. Guarde-a no gerenciador de senhas.
- **NÃO FECHE A JANELA** em nenhum momento.

---

## Passo 5. Testar o novo login (o passo mais importante)

No fim, o script mostra um quadro "IMPORTANTE: NÃO FECHE ESTA JANELA" e
fica esperando. Faça assim:

1. **Deixe a janela atual aberta.**
2. Abra **outra** janela do PowerShell (ou Terminal).
3. Digite o comando que o quadro mostra, por exemplo:
   ```
   ssh -p 22 joao@IP-DO-SERVIDOR
   ```
   (troque `joao` pela sua conta e `22` pela porta, se você mudou.)
4. Dentro, digite `sudo whoami`. Ele pede a senha do sudo e deve responder
   `root`.
5. Deu certo? Volte para a **primeira** janela e digite `sim`.

**E se não der certo?** Não entre em pânico e não feche a primeira janela.
Veja a seção [Problemas](#problemas) abaixo. Se não resolver, não faça nada:
no horário que o quadro mostra (10 minutos por padrão), o SSH e o firewall
voltam **sozinhos** a como estavam antes. É a "rede de segurança".

> Se você mudou a porta do SSH, ao digitar `sim` o script fecha a porta 22,
> porque você já provou que entra pela nova.

---

## Passo 6. Reiniciar (se ele pedir)

Se o resumo final disser "Há um reinício pendente", reinicie quando for um
bom momento:

```
sudo reboot
```

Espere 1 minuto e entre de novo com `ssh -p PORTA sua-conta@IP-DO-SERVIDOR`.

Pronto: o servidor está no padrão. A partir de agora, entre sempre com a sua
conta (nunca mais como root).

---

## Depois: o dia a dia

| Quero... | Comando |
| --- | --- |
| Conferir se tudo continua certo (não muda nada) | `sudo bash ~/safe-vps/safe-vps.sh --conferir` |
| Rodar de novo com as mesmas respostas | `sudo bash ~/safe-vps/safe-vps.sh` |
| Mudar alguma resposta (ex.: abrir outra porta) | `sudo bash ~/safe-vps/safe-vps.sh --perguntar-de-novo` |
| Pegar a versão mais nova do script | `cd ~/safe-vps && git pull` |
| Ver quem foi bloqueado pelo fail2ban | `sudo fail2ban-client status sshd` |
| Ver as regras do firewall | `sudo ufw status verbose` |
| Ver as sugestões do Lynis | `sudo grep '^suggestion' /var/log/lynis-report.dat` |

> Se você rodou o script como root no passo 3, a pasta ficou em
> `/root/safe-vps`. Para tê-la na sua conta: entre com a sua conta e repita o
> `git clone` do passo 3.

---

## Problemas

### "Permission denied (publickey)" ao entrar

O servidor não reconheceu a sua chave.

- Confira se está usando o **nome da conta** certo (o que você respondeu na
  pergunta 1), e não `root`.
- Confira a **porta**: `ssh -p 2222 ...` se você mudou para 2222.
- Se você tem mais de uma chave, diga qual usar:
  `ssh -i ~/.ssh/id_ed25519 -p PORTA conta@IP-DO-SERVIDOR`
- Na primeira janela (que ainda está aberta), veja quais chaves a conta tem:
  `cat /home/SUA-CONTA/.ssh/authorized_keys`. A sua linha `.pub` precisa estar
  lá.

### "Connection refused" ou "Connection timed out"

- A porta está errada, ou o firewall do **provedor** (no painel dele, às
  vezes chamado "Security group" ou "Firewall") não deixa passar a porta nova.
  Se você mudou a porta do SSH, libere a porta nova também no painel do
  provedor.

### "Too many authentication failures"

O seu computador ofereceu várias chaves erradas antes da certa. Use
`ssh -i ~/.ssh/id_ed25519 ...` para indicar a chave.

### Fiquei trancado do lado de fora

1. Espere o horário do "desfazer automático" (mostrado no quadro). Depois
   dele, o SSH volta como era antes; tente entrar como entrava antes.
2. Se não der, use o **console do provedor** (no navegador). Entre com a sua
   conta e senha do sudo, e rode `sudo bash /root/safe-vps/safe-vps.sh
   --conferir` para ver o que está errado.
3. Último recurso: o arquivo `/etc/ssh/sshd_config.d/00-safe-vps.conf` contém
   todas as mudanças do SSH. Apagar ele (`sudo rm` esse arquivo) e rodar
   `sudo systemctl restart ssh` devolve o SSH ao padrão do Ubuntu.

### O script diz [ERRO] em alguma linha

Leia a mensagem: ela diz o que falhou. Problemas de instalação de programas
ficam registrados em `/var/log/safe-vps-apt.log`. Rodar o script de novo é
seguro.

### "não consegui criar /swapfile"

Alguns tipos de VPS (OpenVZ, LXC) não permitem swap. Rode de novo com
`--perguntar-de-novo` e responda `0` na pergunta da swap.

---

## Usar sem perguntas (para quem já conhece)

Copie `exemplo-respostas.conf`, ajuste os valores e rode:

```
sudo bash safe-vps.sh --respostas minhas-respostas.conf
```

Com `--aplicar`, ele também não pergunta "Posso aplicar?". O desfazer
automático continua valendo: confirme o login com
`sudo bash safe-vps.sh --confirmar` depois de testar.
