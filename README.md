# safe-vps

Um procedimento padrão para **começar uma VPS Ubuntu com segurança**, num
único script que pergunta antes, confere antes e só muda algo com o seu "sim".

- **Primeira vez?** Siga o [manual de instalação](MANUAL.md), passo a passo.
- **Quer entender o que muda?** Continue lendo este README.

> **Aviso.** Este script vem **sem garantia** (veja a [licença](LICENSE)). Ele
> foi pensado para um servidor **novo**. Leia o que ele faz antes de rodar num
> servidor que já está em uso, e tenha sempre o acesso ao console do provedor
> à mão.

---

## Como o script funciona

```
sudo bash safe-vps.sh
```

1. **Perguntas.** 12 perguntas (conta, chave, porta, portas abertas...), cada
   uma com explicação e sugestão. Nada muda nessa hora.
2. **Conferência.** Olha o servidor e mostra `[ok]` (já está certo) ou
   `[falta]` (vai mudar). Ainda nada muda.
3. **"Posso aplicar essas mudanças agora?"** Só com `sim` ele continua.
4. **Aplicação**, com **rede de segurança**: antes de mexer no SSH e no
   firewall, ele guarda uma cópia e agenda um "desfazer" para daqui a 10
   minutos. Você testa o login numa janela nova e confirma. Se não confirmar
   (por exemplo, porque ficou trancado do lado de fora), tudo de SSH e
   firewall volta sozinho a como estava.
5. **Auditoria Lynis** (opcional): uma nota de 0 a 100.

Rodar de novo é seguro: o que já está certo não é mexido. As respostas ficam
salvas em `/etc/safe-vps/respostas.conf` e são oferecidas na próxima vez.

### Opções

| Opção | O que faz |
| --- | --- |
| *(nenhuma)* | Pergunta, confere e só aplica com o seu "sim" |
| `--conferir` | Só confere. Nunca muda nada |
| `--aplicar` | Aplica sem a pergunta "Posso aplicar?" |
| `--confirmar` | Confirma que o novo login funcionou (cancela o desfazer automático) |
| `--perguntar-de-novo` | Ignora as respostas salvas e pergunta tudo |
| `--respostas ARQUIVO` | Lê as respostas de um arquivo e não pergunta nada (veja [exemplo-respostas.conf](exemplo-respostas.conf)) |
| `--ajuda` | Mostra a ajuda |

---

## As perguntas

| # | Pergunta | Sugestão | Para que serve |
| --- | --- | --- | --- |
| 1 | Conta de administrador | quem rodou o `sudo`, ou `admin` | A conta com que você vai entrar. O root deixa de entrar direto |
| 2 | Chave SSH pública | (pular) | Para entrar sem senha. Pulando, ele copia as chaves que o provedor colocou no root |
| 3 | Nome do servidor | manter | Para não confundir um servidor com outro |
| 4 | Fuso horário | `America/Sao_Paulo` | Horário dos logs e das tarefas agendadas |
| 5 | Porta do SSH | `22` | Ver a etapa 5 sobre trocar ou não |
| 6 | Túnel SSH | `sim` | Acessar painéis internos só pelo seu computador |
| 7 | Portas abertas para a internet | site: `80/tcp 443/tcp 443/udp` | O resto fica fechado |
| 8 | Atualizar tudo agora | `sim` | Num servidor novo, sim |
| 9 | Reinício automático | `nao` | Ou um horário, como `04:00` |
| 10 | Swap | `2G` | Memória extra no disco |
| 11 | Docker (e usar sem sudo) | `sim` / `sim` | Para rodar aplicações em contêineres |
| 12 | Auditoria Lynis | `sim` | Nota de segurança no fim |
| + | Avançadas (opcional) | 5 erros / 1h, logs 500M, 10 min | fail2ban, tamanho dos logs, tempo do desfazer |

---

## O que cada etapa muda, como e por quê

As 15 etapas, na ordem em que rodam.

### 1. Sistema

- **O quê:** só confere. Vê se é Ubuntu 24.04, se o systemd está rodando e se
  há espaço no disco.
- **Por quê:** o script foi feito e testado no Ubuntu 24.04. Em outra versão
  ele avisa, porque algum detalhe pode ser diferente.

### 2. Programas necessários

- **O quê:** instala `ufw` (firewall), `fail2ban` (bloqueio de quem erra
  login), `unattended-upgrades` (atualizações automáticas), `lynis`
  (auditoria), `curl`, `gnupg` e `ca-certificates` (para baixar e conferir
  assinaturas). Se você respondeu "sim" na pergunta 8, também instala todas
  as atualizações que já existem (`apt-get upgrade`).
- **Como:** `apt-get install`. A saída vai para `/var/log/safe-vps-apt.log`.
- **Por quê:** são as ferramentas das próximas etapas. E um servidor novo
  quase sempre vem com atualizações de segurança atrasadas.

### 3. Relógio e nome

- **O quê:** coloca o fuso horário que você escolheu, liga o acerto do
  relógio pela internet (NTP) e, se pediu, troca o nome do servidor.
- **Como:** `timedatectl set-timezone`, `timedatectl set-ntp true`,
  `hostnamectl set-hostname` (e uma linha em `/etc/hosts`).
- **Por quê:** com o relógio certo, os logs mostram a hora real de cada
  coisa, e as conexões seguras (HTTPS) não falham. Tarefas agendadas seguem o
  fuso.

### 4. Conta de administrador

- **O quê:** cria a sua conta (se não existir), coloca no grupo `sudo`,
  coloca a sua chave SSH nela e garante que ela tem senha.
- **Como:** `adduser`, `usermod -aG sudo` e `~/.ssh/authorized_keys`. Sem
  chave informada, copia as do root (colocadas pelo provedor). Sem senha, pede
  para você criar.
- **Por quê:**
  - Entrar como **root** é perigoso: um erro de digitação faz estrago sem
    perguntar, e "root" é o primeiro nome que os robôs tentam. Com uma conta
    sua, você só vira administrador quando precisa (`sudo`).
  - O **sudo pede senha**, de propósito. É uma segunda barreira: quem roubar a
    sua chave SSH ainda não consegue administrar o servidor sem a senha.

### Rede de segurança (antes das etapas 5 e 6)

- **O quê:** guarda uma cópia de como o SSH e o firewall estão e agenda um
  "desfazer" para daqui a 10 minutos (ou o tempo que você escolheu).
- **Como:** cópia em `/var/backups/safe-vps/` e um temporizador do systemd
  (`safe-vps-desfazer`), cancelado quando você confirma o login.
- **Por quê:** mudar SSH e firewall é a forma mais comum de ficar trancado do
  lado de fora do próprio servidor. Assim, mesmo que a conexão caia no meio,
  o acesso volta sozinho.

### 5. SSH (como você entra no servidor)

- **O quê:** desliga o login do root e o login por senha, deixa entrar só a
  sua conta, com chave, e usa só criptografia moderna.
- **Como:** um arquivo só, `/etc/ssh/sshd_config.d/00-safe-vps.conf` (o
  `sshd_config` do Ubuntu não é tocado). A configuração é testada antes de
  valer; se algo não bater, volta como era. Se a sua conta não tiver chave,
  esta etapa não roda, para você não ficar trancado do lado de fora.
- **Cada linha, e por quê:**

  | Linha | Por quê |
  | --- | --- |
  | `Port 22` (ou a sua) | A porta em que o SSH escuta |
  | `PermitRootLogin no` | root não entra direto (veja a etapa 4) |
  | `PasswordAuthentication no` e `KbdInteractiveAuthentication no` | Sem login por senha: os robôs que testam milhões de senhas não têm o que adivinhar. Só entra quem tem a chave |
  | `PubkeyAuthentication yes` | Login por chave ligado |
  | `PermitEmptyPasswords no` | Conta sem senha nunca entra |
  | `AllowUsers sua-conta` | Só a sua conta entra por SSH, mesmo que um programa crie outras |
  | `MaxAuthTries 4` | 4 tentativas por conexão. Suficiente para um computador que oferece 2 ou 3 chaves antes da certa |
  | `LoginGraceTime 30` | 30 segundos para terminar o login, senão a conexão cai |
  | `ClientAliveInterval 300` e `ClientAliveCountMax 2` | Conexões esquecidas abertas caem depois de uns 10 minutos sem resposta |
  | `AllowTcpForwarding local` (ou `no`) | Permite (ou não) o túnel SSH da pergunta 6. `local` só deixa você trazer uma porta do servidor para o seu computador, não o contrário |
  | `AllowAgentForwarding no` e `X11Forwarding no` | Recursos que um servidor não usa e que podem ser abusados |
  | `PermitUserEnvironment no` | Um usuário não consegue mudar variáveis que afetam o login |
  | `LogLevel VERBOSE` | O log registra qual chave entrou. Ajuda a investigar |
  | `KexAlgorithms`, `Ciphers`, `MACs` | Só algoritmos modernos, incluindo os resistentes a computadores quânticos quando o OpenSSH tem. O script só coloca os que o OpenSSH do servidor conhece |

- **Sobre trocar a porta:** trocar a 22 por outra **não deixa o servidor mais
  seguro de verdade**, porque quem ataca a sério acha a porta nova em minutos.
  Só diminui o barulho de robôs nos logs. Por isso a sugestão é deixar 22. Se
  você trocar, o script faz em duas fases: abre a nova **e mantém a 22**; só
  depois que você confirma que entrou pela nova, ele fecha a 22. Libere a
  porta nova também no firewall do painel do provedor, se ele tiver um.

### 6. Firewall (ufw)

- **O quê:** bloqueia toda conexão que chega, menos o SSH e as portas que
  você escolheu. Libera tudo que sai.
- **Como:** `ufw limit` na porta do SSH (antes de ligar, para não cortar a
  sessão), `ufw allow` para cada porta da sua lista, `ufw default deny
  incoming` e `ufw enable`.
- **Por quê:** cada porta aberta é uma porta por onde alguém pode tentar
  entrar. Fechar tudo e abrir só o necessário é a regra básica. O `limit` no
  SSH recusa por um tempo quem abre mais de 6 conexões em 30 segundos, o que
  segura enxurradas de tentativas.

### 7. fail2ban

- **O quê:** quem errar o login **5 vezes em 10 minutos** fica bloqueado por
  **1 hora** (valores das opções avançadas).
- **Como:** arquivo `/etc/fail2ban/jail.d/safe-vps.local`, testado antes de valer.
- **Por quê:** mesmo sem login por senha, robôs ficam tentando o dia todo.
  Bloquear quem insiste deixa os logs limpos e gasta menos do servidor.

### 8. Atualizações automáticas de segurança

- **O quê:** o servidor instala sozinho, todo dia, as correções de
  segurança. E segue a sua resposta sobre reiniciar sozinho.
- **Como:** `/etc/apt/apt.conf.d/20auto-upgrades` (liga a rotina diária) e
  `/etc/apt/apt.conf.d/52safe-vps-reboot` (reinicia ou não, e em que horário).
- **Por quê:** a maioria das invasões usa falhas que já têm correção. Algumas
  correções só valem depois de reiniciar, o que tira o servidor do ar por 1
  ou 2 minutos; por isso o horário é escolha sua.

### 9. Proteções do kernel e da rede

- **O quê:** liga proteções do Linux que vêm desligadas ou frouxas.
- **Como:** arquivo `/etc/sysctl.d/90-safe-vps.conf`, aplicado na hora e a
  cada reinício. Lista baseada na do Gaia-harden.
- **Por quê, em grupos:**
  - **Rede** (`rp_filter`, `accept_redirects`, `send_redirects`,
    `accept_source_route`): descarta pacotes com remetente falso e ignora
    "redirecionamentos", que são pedidos para o servidor mandar o tráfego para
    outro lugar. Um servidor comum nunca precisa disso.
  - **Registro** (`log_martians`): anota no log pacotes com endereços
    impossíveis, que costumam ser sinal de ataque.
  - **Ruído** (`icmp_echo_ignore_broadcasts`,
    `icmp_ignore_bogus_error_responses`): não responde a "pings" para a rede
    inteira (usados para amplificar ataques) nem a mensagens de erro falsas.
  - **Enxurrada de conexões** (`tcp_syncookies`, `tcp_rfc1337`): continua
    atendendo mesmo quando alguém manda milhares de conexões pela metade (o
    ataque "SYN flood").
  - **Kernel** (`kptr_restrict`, `dmesg_restrict`, `ptrace_scope`,
    `unprivileged_bpf_disabled`, `bpf_jit_harden`, `randomize_va_space`,
    `sysrq`): esconde endereços e mensagens internas do kernel de quem não é
    administrador, impede um programa de espiar a memória de outro e
    embaralha onde cada coisa fica na memória. Dificulta transformar uma
    falha pequena em controle total.
  - **Arquivos** (`protected_hardlinks`, `protected_symlinks`,
    `protected_fifos`, `protected_regular`, `suid_dumpable`): bloqueia
    truques com atalhos em pastas compartilhadas como `/tmp` e impede cópias
    da memória de programas que rodam com permissões especiais (onde podem
    estar senhas).

### 10. Logs do sistema

- **O quê:** os logs do Ubuntu passam a ser guardados mesmo depois de
  reiniciar, comprimidos, até no máximo 500 MB (ou o valor que você escolheu).
- **Como:** arquivo `/etc/systemd/journald.conf.d/90-safe-vps.conf`.
- **Por quê:** se algo acontecer, você quer poder ver o que houve **antes**
  do último reinício. E com limite, os logs nunca enchem o disco.

### 11. Swap

- **O quê:** se o servidor não tiver swap, cria um arquivo de swap do tamanho
  escolhido, e diz ao Linux para usar a swap só quando faltar memória de verdade.
- **Como:** `/swapfile`, uma linha em `/etc/fstab` e `vm.swappiness = 10`.
- **Por quê:** quando a RAM acaba e não há swap, o Linux mata um programa
  para liberar memória, e pode ser justamente o banco de dados. A swap é mais
  lenta, mas evita isso. Se o servidor já tiver swap, nada muda.

### 12. Serviços de rede sem uso

- **O quê:** desliga `rpcbind`, `avahi` e `cups` se estiverem ligados, e
  confere se o AppArmor está ligado.
- **Como:** `systemctl disable --now`.
- **Por quê:** são serviços de rede local e impressoras, que um servidor na
  internet não usa. Serviço desligado é um a menos para ter falha.

### 13. Docker (opcional)

- **O quê:** instala o Docker do **repositório oficial** e, se você escolheu,
  deixa a sua conta usar o Docker sem `sudo`.
- **Como:** confere a assinatura do repositório do Docker antes de instalar;
  se não bater, não instala nada.
- **Por quê:** versões mais novas, com garantia de que vieram do Docker.
- **Atenção ao "sem sudo":** quem está no grupo `docker` consegue fazer
  qualquer coisa no servidor. Por isso é uma pergunta.

### 14. Portas abertas para a internet

- **O quê:** só confere. Lista tudo que está escutando de verdade e avisa o
  que não está na sua lista.
- **Como:** `ss -tuln`.
- **Por quê:** **o Docker abre as portas dos contêineres sem passar pelo
  ufw.** Um `ports: "5432:5432"` num docker-compose deixa o banco de dados
  aberto para a internet, mesmo com o firewall dizendo que está fechado. Esta
  etapa mostra isso. A solução é publicar só em `127.0.0.1`
  (`"127.0.0.1:5432:5432"`) ou não publicar a porta.

### 15. Auditoria Lynis (opcional)

- **O quê:** roda o [Lynis](https://cisofy.com/lynis/), que **só lê** o
  servidor e dá uma nota de 0 a 100 com sugestões.
- **Como:** `lynis audit system`. Relatório em `/var/log/lynis-report.dat` e
  log em `/var/log/lynis.log`.
- **Por quê:** uma opinião independente e um número para comparar
  servidores. Acima de 70 já é bom; 100 não é a meta.

---

## O que o script NÃO faz, de propósito

- **Não deixa o `sudo` sem senha.**
- **Não reinicia o servidor nem o Docker sozinho** (a não ser que você escolha
  um horário na pergunta 9).
- **Não muda o Docker para obedecer o firewall** (pode derrubar sites que
  dependem das portas publicadas). Ver a etapa 14.
- **Não fecha portas que você abriu antes** e que não estão na lista: só avisa.
- **Não cuida da sua aplicação**: HTTPS, senhas do banco, backups.

---

## Arquivos que o script cria ou muda

| Arquivo | Etapa |
| --- | --- |
| `/etc/ssh/sshd_config.d/00-safe-vps.conf` | 5. SSH |
| `/etc/ufw/*` (pelo comando `ufw`) | 6. Firewall |
| `/etc/fail2ban/jail.d/safe-vps.local` | 7. fail2ban |
| `/etc/apt/apt.conf.d/20auto-upgrades` e `52safe-vps-reboot` | 8. Atualizações |
| `/etc/sysctl.d/90-safe-vps.conf` | 9. Kernel e rede |
| `/etc/systemd/journald.conf.d/90-safe-vps.conf` | 10. Logs |
| `/swapfile`, `/etc/fstab`, `/etc/sysctl.d/91-safe-vps-swap.conf` | 11. Swap |
| `/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.list` | 13. Docker |
| `/etc/safe-vps/respostas.conf` | suas respostas |
| `/var/backups/safe-vps/` | cópias para o desfazer automático |
| `/var/log/safe-vps-apt.log`, `/var/log/safe-vps-desfeito.log` | registros |

**Para desfazer uma etapa:** apague o arquivo dela e reinicie o serviço
correspondente (ex.: `sudo systemctl restart ssh`).

---

## Testado em

Ubuntu 24.04 LTS. Em outros sistemas o script avisa e continua, mas confira
cada etapa.

## Sugestões

Achou algo errado, inseguro ou que dá para explicar melhor? Abra uma *issue*.

## Créditos e licença

- Feito com o auxílio do [Claude Code](https://claude.com/claude-code).
- Ideia inspirada no [Gaia-harden](https://github.com/Black-Ghost-Corp/Gaia-harden)
  (Apache-2.0), de onde vem também a base da lista da etapa 9. Detalhes no
  arquivo [NOTICE](NOTICE).
- Licença: [Apache-2.0](LICENSE).
