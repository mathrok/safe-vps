#!/usr/bin/env bash
# safe-vps: procedimento padrão de segurança para um servidor (VPS) Ubuntu.
#
# Feito para um servidor NOVO com Ubuntu 24.04, logo depois de comprado,
# antes de instalar qualquer aplicação. Também pode rodar num servidor que
# já está em uso, só para conferir o que falta.
#
# Como usar (sempre como administrador, com sudo ou como root):
#   sudo bash safe-vps.sh              faz as perguntas, CONFERE o servidor,
#                                      mostra o que falta e só muda algo se
#                                      você responder "sim".
#   sudo bash safe-vps.sh --conferir   só confere. Nunca muda nada.
#   sudo bash safe-vps.sh --aplicar    aplica sem a pergunta final "posso
#                                      aplicar?" (as outras perguntas continuam).
#   sudo bash safe-vps.sh --confirmar  confirma que o novo login funcionou
#                                      (cancela o "desfazer automático").
#
# Outras opções:
#   --respostas ARQUIVO     lê as respostas de um arquivo e não pergunta nada
#                           (veja exemplo-respostas.conf).
#   --perguntar-de-novo     ignora as respostas salvas e pergunta tudo de novo.
#   --ajuda                 mostra este texto.
#
# Rodar de novo é seguro: o que já está certo não é mexido.
# Leia o README.md para saber o que cada etapa muda, como e por quê.
#
# Feito com o auxílio do Claude Code (Anthropic). A ideia de padronizar o
# início de uma VPS num script veio do projeto Gaia-harden
# (github.com/Black-Ghost-Corp/Gaia-harden, licença Apache-2.0).
# Licença deste script: Apache-2.0 (arquivos LICENSE e NOTICE).
set -uo pipefail

VERSION=1.0.0

# ---------------------------------------------------------------------------
# Onde ficam os arquivos que este script cria. Todos têm "safe-vps" no nome,
# para você saber de onde vieram.
# ---------------------------------------------------------------------------
STATE_DIR=/etc/safe-vps
ANSWERS_FILE=$STATE_DIR/respostas.conf
PORT_CONFIRMED_FILE=$STATE_DIR/porta-ssh-confirmada
BACKUP_ROOT=/var/backups/safe-vps
ROLLBACK_UNIT=safe-vps-desfazer
SSH_DROPIN=/etc/ssh/sshd_config.d/00-safe-vps.conf
FAIL2BAN_JAIL=/etc/fail2ban/jail.d/safe-vps.local
SYSCTL_FILE=/etc/sysctl.d/90-safe-vps.conf
SWAPPINESS_FILE=/etc/sysctl.d/91-safe-vps-swap.conf
JOURNALD_FILE=/etc/systemd/journald.conf.d/90-safe-vps.conf
UPGRADES_FILE=/etc/apt/apt.conf.d/20auto-upgrades
UPGRADES_REBOOT_FILE=/etc/apt/apt.conf.d/52safe-vps-reboot
APT_LOG=/var/log/safe-vps-apt.log

# Chave oficial de assinatura do Docker. Se a chave baixada tiver outra
# impressão digital, nada é instalado. Publicada em
# https://docs.docker.com/engine/install/ubuntu/
DOCKER_KEY_FINGERPRINT=9DC858229FC7DD38854AE2D88D81803C0EBFCD88

# ---------------------------------------------------------------------------
# Respostas (valores personalizáveis) e seus valores sugeridos.
# A ordem aqui é a ordem em que são salvas em respostas.conf.
# ---------------------------------------------------------------------------
ANSWER_KEYS=(ADMIN_USER SSH_KEY NEW_HOSTNAME TIMEZONE SSH_PORT SSH_TUNNEL
  PUBLIC_PORTS UPGRADE_NOW AUTO_REBOOT SWAP_SIZE INSTALL_DOCKER DOCKER_GROUP
  RUN_LYNIS FAIL2BAN_MAXRETRY FAIL2BAN_BANTIME JOURNAL_MAX ROLLBACK_MINUTES)

ADMIN_USER=""
SSH_KEY=""
NEW_HOSTNAME=""
TIMEZONE=America/Sao_Paulo
SSH_PORT=22
SSH_TUNNEL=sim
PUBLIC_PORTS="80/tcp 443/tcp 443/udp"
UPGRADE_NOW=sim
AUTO_REBOOT=nao
SWAP_SIZE=2G
INSTALL_DOCKER=sim
DOCKER_GROUP=sim
RUN_LYNIS=sim
FAIL2BAN_MAXRETRY=5
FAIL2BAN_BANTIME=1h
JOURNAL_MAX=500M
ROLLBACK_MINUTES=10

MODE=ask          # ask | check | apply | confirm
ANSWERS_FROM=""
REASK=0

usage() { sed -n '2,/^set -uo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

while (($#)); do
  case $1 in
    --conferir | --check) MODE=check ;;
    --aplicar | --apply) MODE=apply ;;
    --confirmar | --confirm) MODE=confirm ;;
    --respostas | --answers) ANSWERS_FROM=${2:?--respostas precisa do caminho do arquivo}; shift ;;
    --perguntar-de-novo) REASK=1 ;;
    -h | --ajuda | --help) usage; exit 0 ;;
    --versao | --version) echo "safe-vps $VERSION"; exit 0 ;;
    *) echo "Opção desconhecida: $1 (veja --ajuda)" >&2; exit 2 ;;
  esac
  shift
done

if [[ $EUID -ne 0 ]]; then
  echo "Rode como administrador:  sudo bash $0 $*" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pequenas ajudas para escrever na tela
# ---------------------------------------------------------------------------
APPLY=0
MISSING=0
FAILED=0
SSH_CHANGED=0
FIREWALL_CHANGED=0
ok() { printf '  [ok]       %s\n' "$*"; }
missing() { printf '  [falta]    %s\n' "$*"; MISSING=$((MISSING + 1)); }
fixed() { printf '  [feito]    %s\n' "$*"; }
warn() { printf '  [atenção]  %s\n' "$*"; }
fail() { printf '  [ERRO]     %s\n' "$*"; FAILED=$((FAILED + 1)); }
section() { printf '\n== %s\n' "$*"; }
has() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
is_yes() { [[ ${1,,} =~ ^(s|sim|y|yes)$ ]]; }

# Existe um teclado do outro lado? (Funciona mesmo com "curl ... | sudo bash".)
HAS_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAS_TTY=1; fi

# apt-get sem perguntas; a saída longa vai para um arquivo, não para a tela.
# "confold" = se um pacote trouxer uma versão nova de um arquivo de
# configuração que foi mudado aqui, fica valendo o nosso.
apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold "$@" >>"$APT_LOG" 2>&1
}

# want_file CAMINHO PERMISSAO CONTEUDO DESCRICAO
# Devolve 0 quando o arquivo já tem exatamente esse conteúdo. Senão, no modo
# "conferir" avisa que falta; no modo "aplicar" grava o arquivo (por um
# arquivo temporário, para nunca existir um arquivo pela metade) e devolve 1,
# para quem chamou saber que mudou e recarregar o serviço.
want_file() {
  local path=$1 mode=$2 content=$3 what=$4 tmp
  if [[ -f $path && "$(cat "$path")" == "$content" ]]; then
    ok "$what"
    return 0
  fi
  if ((!APPLY)); then
    missing "$what ($path)"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "$path.XXXXXX")
  printf '%s\n' "$content" >"$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$path"
  fixed "$what ($path)"
  return 1
}

KEY_REGEX='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) AAAA[A-Za-z0-9+/=]+'

# Quantas linhas de um authorized_keys têm uma chave pública.
count_keys() {
  [[ -f $1 ]] || { echo 0; return; }
  grep -cE "^[^#]*$KEY_REGEX" "$1" || true
}

user_home() { getent passwd "$1" | cut -d: -f6; }

# ---------------------------------------------------------------------------
# Validação das respostas. Cada função devolve 0 (válido) ou 1 e escreve o
# motivo, para a pergunta ser feita de novo.
# ---------------------------------------------------------------------------
valid_ADMIN_USER() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "use só letras minúsculas, números, - e _ (começando por letra)"; return 1; }
  [[ $1 != root ]] || { echo "escolha um nome diferente de root"; return 1; }
}
valid_SSH_KEY() {
  [[ -z $1 ]] && return 0
  [[ $1 =~ ^$KEY_REGEX ]] || { echo "não parece uma chave pública (começa com ssh-ed25519 AAAA...). Cole a linha do arquivo .pub, não a chave privada"; return 1; }
}
valid_NEW_HOSTNAME() {
  [[ -z $1 || $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || { echo "use letras minúsculas, números e -, sem espaços (ex.: vps-estudos)"; return 1; }
}
valid_TIMEZONE() {
  [[ -n $1 && $1 != *..* && -f /usr/share/zoneinfo/$1 ]] || { echo "fuso desconhecido. Exemplos: America/Sao_Paulo, America/Manaus, Europe/Lisbon, UTC"; return 1; }
}
valid_port_number() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_SSH_PORT() {
  valid_port_number "$1" || { echo "uma porta é um número de 1 a 65535"; return 1; }
  [[ $1 == 22 ]] || ((10#$1 >= 1024)) || { echo "fora a 22, use uma porta de 1024 a 65535 (ex.: 2222)"; return 1; }
}
valid_yes_no() { [[ $1 == sim || $1 == nao ]] || { echo "responda sim ou nao"; return 1; }; }
valid_SSH_TUNNEL() { valid_yes_no "$1"; }
valid_UPGRADE_NOW() { valid_yes_no "$1"; }
valid_INSTALL_DOCKER() { valid_yes_no "$1"; }
valid_DOCKER_GROUP() { valid_yes_no "$1"; }
valid_RUN_LYNIS() { valid_yes_no "$1"; }
valid_PUBLIC_PORTS() {
  local p num
  for p in $1; do
    [[ $p =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || { echo "'$p' não está no formato número/tcp ou número/udp (ex.: 443/tcp)"; return 1; }
    num=${BASH_REMATCH[1]}
    valid_port_number "$num" || { echo "'$p': porta fora de 1-65535"; return 1; }
    [[ $num != "$SSH_PORT" && $num != 22 ]] || { echo "'$p': a porta do SSH é cuidada à parte, não coloque aqui"; return 1; }
  done
}
valid_AUTO_REBOOT() {
  [[ $1 == nao || $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "responda nao, ou um horário HH:MM (ex.: 04:00)"; return 1; }
}
valid_SWAP_SIZE() { [[ $1 =~ ^([0-9]+[MG]|0)$ ]] || { echo "use um tamanho como 1G, 2G, 512M, ou 0 para nenhum"; return 1; }; }
# shellcheck disable=SC2015 # aqui A && B || C é o que queremos
valid_FAIL2BAN_MAXRETRY() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 2 && 10#$1 <= 20)) || { echo "um número de 2 a 20"; return 1; }; }
valid_FAIL2BAN_BANTIME() { [[ $1 =~ ^[0-9]+[mhd]$ ]] || { echo "use número + m, h ou d (ex.: 30m, 1h, 1d)"; return 1; }; }
valid_JOURNAL_MAX() { [[ $1 =~ ^[0-9]+[MG]$ ]] || { echo "use um tamanho como 200M, 500M, 1G"; return 1; }; }
# shellcheck disable=SC2015
valid_ROLLBACK_MINUTES() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 3 && 10#$1 <= 60)) || { echo "um número de 3 a 60"; return 1; }; }

# Nenhuma resposta pode ter aspas, barra invertida ou quebra de linha
# (elas são gravadas entre aspas em respostas.conf).
safe_text() { [[ $1 != *'"'* && $1 != *\\* && $1 != *$'\n'* && $1 != *'`'* ]]; }

validate_all() {
  local k msg bad=0
  for k in "${ANSWER_KEYS[@]}"; do
    if ! safe_text "${!k}"; then
      echo "Resposta inválida em $k: não use aspas, \\ ou \`" >&2
      bad=1
    elif ! msg=$("valid_$k" "${!k}"); then
      echo "Resposta inválida em $k='${!k}': $msg" >&2
      bad=1
    fi
  done
  ((!bad))
}

# Lê respostas de um arquivo SEM executá-lo: só aceita linhas CHAVE="valor"
# com chaves conhecidas. Assim um arquivo estranho não roda comandos.
load_answers() {
  local file=$1 line key value
  [[ -r $file ]] || { echo "Não consegui ler $file" >&2; exit 2; }
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^([A-Z_0-9]+)=\"(.*)\"[[:space:]]*$ ]]; then
      key=${BASH_REMATCH[1]}
      value=${BASH_REMATCH[2]}
      if [[ " ${ANSWER_KEYS[*]} " == *" $key "* ]]; then
        printf -v "$key" '%s' "$value"
      else
        echo "Aviso: $file tem uma chave desconhecida ($key); ignorada." >&2
      fi
    else
      echo "Aviso: linha ignorada em $file: $line" >&2
    fi
  done <"$file"
}

save_answers() {
  local k
  install -d -m 700 "$STATE_DIR"
  {
    echo "# Respostas usadas pelo safe-vps $VERSION em $(date '+%Y-%m-%d %H:%M')."
    echo "# Na próxima vez o script oferece usar estas mesmas respostas."
    for k in "${ANSWER_KEYS[@]}"; do printf '%s="%s"\n' "$k" "${!k}"; done
  } >"$ANSWERS_FILE.tmp"
  chmod 600 "$ANSWERS_FILE.tmp"
  mv "$ANSWERS_FILE.tmp" "$ANSWERS_FILE"
}

# ---------------------------------------------------------------------------
# Perguntas
# ---------------------------------------------------------------------------
# ask VARIAVEL "pergunta" "explicação"
# Mostra a explicação, a pergunta e o valor atual entre colchetes.
# Enter vazio = aceita o valor entre colchetes.
ask() {
  local var=$1 question=$2 help=$3 answer msg
  printf '\n%s\n' "$help"
  while true; do
    read -r -p "> $question [${!var}]: " answer </dev/tty || exit 1
    answer=${answer#"${answer%%[![:space:]]*}"}
    answer=${answer%"${answer##*[![:space:]]}"}
    [[ -z $answer ]] && answer=${!var}
    if ! safe_text "$answer"; then
      echo "  Não use aspas, \\ ou \`. Tente de novo."
      continue
    fi
    if msg=$("valid_$var" "$answer"); then
      printf -v "$var" '%s' "$answer"
      return 0
    fi
    echo "  $msg. Tente de novo."
  done
}

# Pergunta de sim ou não; guarda "sim" ou "nao".
ask_yes_no() {
  local var=$1 question=$2 help=$3 answer
  printf '\n%s\n' "$help"
  while true; do
    read -r -p "> $question (sim/nao) [${!var}]: " answer </dev/tty || exit 1
    [[ -z $answer ]] && answer=${!var}
    case ${answer,,} in
      s | sim | y | yes) printf -v "$var" sim; return 0 ;;
      n | nao | não | no) printf -v "$var" nao; return 0 ;;
      *) echo "  Responda sim ou nao." ;;
    esac
  done
}

# Pergunta solta, que não vira resposta salva. Devolve 0 para "sim".
confirm() {
  local question=$1 default=$2 answer
  read -r -p "> $question (sim/nao) [$default]: " answer </dev/tty || return 1
  [[ -z $answer ]] && answer=$default
  is_yes "$answer"
}

ask_all() {
  local ram_mb
  echo
  echo "Vou fazer algumas perguntas. Cada uma explica o que é e já traz uma"
  echo "sugestão entre [colchetes]. Aperte Enter para aceitar a sugestão, ou"
  echo "digite outro valor. Nada é mudado no servidor durante as perguntas."

  # Sugestão de nome: quem chamou o sudo (se não for root).
  if [[ -z $ADMIN_USER && -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then ADMIN_USER=$SUDO_USER; fi
  [[ -z $ADMIN_USER ]] && ADMIN_USER="admin"
  ask ADMIN_USER "Nome da sua conta de administrador" \
"1/12  CONTA DE ADMINISTRADOR
   É com esta conta que você vai entrar no servidor daqui em diante. O login
   direto como root será desligado. Use um nome só seu, em minúsculas, sem
   espaços (ex.: joao). Se a conta não existir, ela é criada."

  local home keys=0
  home=$(user_home "$ADMIN_USER")
  [[ -n $home ]] && keys=$(count_keys "$home/.ssh/authorized_keys")
  ask SSH_KEY "Cole aqui a sua chave PÚBLICA (ou Enter para pular)" \
"2/12  CHAVE SSH
   A chave é o que deixa você entrar sem senha, e é muito mais segura que uma
   senha. No seu computador ela fica no arquivo id_ed25519.pub (o manual
   explica como criar e copiar). Cole a linha inteira, que começa com
   ssh-ed25519 AAAA...
   Situação agora: a conta '$ADMIN_USER' tem $keys chave(s); o root tem
   $(count_keys /root/.ssh/authorized_keys). Se você pular e a conta não tiver
   nenhuma, o script copia as chaves do root (ou de quem rodou o sudo).
   Sem nenhuma chave, o script NÃO desliga o login por senha, para você não
   ficar trancado do lado de fora."

  ask NEW_HOSTNAME "Nome do servidor (ou Enter para manter '$(hostname)')" \
"3/12  NOME DO SERVIDOR
   Aparece no terminal (ex.: joao@vps-estudos) e ajuda a não confundir um
   servidor com outro quando você tiver mais de um. Opcional."

  ask TIMEZONE "Fuso horário" \
"4/12  FUSO HORÁRIO
   Os horários dos logs e das tarefas agendadas (backups, por exemplo) seguem
   este fuso. Brasília = America/Sao_Paulo. Outros: America/Manaus,
   America/Recife, America/Cuiaba, UTC."

  ask SSH_PORT "Porta do SSH" \
"5/12  PORTA DO SSH
   A porta padrão é 22. Trocar a porta não deixa o servidor mais seguro de
   verdade (quem ataca a sério acha a porta nova em minutos), só diminui o
   barulho de robôs nos logs. Se trocar, o script abre as DUAS portas até
   você confirmar que entrou pela nova, para você não ficar trancado.
   Sugestão para iniciantes: deixar 22."

  ask_yes_no SSH_TUNNEL "Vai usar túnel SSH?" \
"6/12  TÚNEL SSH
   Um túnel deixa você abrir no seu computador um painel que, no servidor,
   está fechado para a internet (ex.: o painel de um banco de dados). É o
   jeito seguro de acessar essas coisas. Se não sabe, responda sim: o túnel
   só funciona para quem já consegue entrar com a sua chave."

  local preset=1 answer
  printf '\n%s\n' "7/12  PORTAS ABERTAS PARA A INTERNET (além do SSH)
   Tudo que não estiver nesta lista fica fechado pelo firewall.
     1) Site ou sistema web: 80/tcp 443/tcp 443/udp  (http, https e http/3)
     2) Nenhuma: só o SSH (servidor de estudos, sem site)
     3) Quero digitar a lista eu mesmo
   Atual: ${PUBLIC_PORTS:-nenhuma}"
  [[ -z $PUBLIC_PORTS ]] && preset=2
  while true; do
    read -r -p "> Escolha 1, 2 ou 3 [$preset]: " answer </dev/tty || exit 1
    case ${answer:-$preset} in
      1) PUBLIC_PORTS="80/tcp 443/tcp 443/udp"; break ;;
      2) PUBLIC_PORTS=""; break ;;
      3)
        echo "   Digite as portas separadas por espaço, no formato número/tcp ou"
        echo "   número/udp. Ex.: 80/tcp 443/tcp 8080/tcp"
        ask PUBLIC_PORTS "Portas" ""
        break
        ;;
      *) echo "  Digite 1, 2 ou 3." ;;
    esac
  done

  ask_yes_no UPGRADE_NOW "Atualizar todos os programas agora?" \
"8/12  ATUALIZAR AGORA
   Instala agora todas as atualizações que já existem (1 a 5 minutos).
   Recomendado num servidor novo. Num servidor em uso, com aplicações rodando,
   você pode preferir 'nao' e atualizar num horário calmo."

  ask AUTO_REBOOT "Reiniciar sozinho? (nao, ou horário HH:MM)" \
"9/12  REINÍCIO AUTOMÁTICO
   As atualizações de segurança são instaladas sozinhas todo dia. Algumas
   (do kernel) só valem depois de reiniciar. Responda 'nao' para você mesmo
   reiniciar quando quiser (o script avisa quando há reinício pendente), ou
   um horário, como 04:00, para o servidor reiniciar sozinho nessa hora
   quando for preciso (fica fora do ar por 1 ou 2 minutos)."

  ram_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo 2>/dev/null)
  ask SWAP_SIZE "Tamanho da swap (0 = nenhuma)" \
"10/12 SWAP (memória extra no disco)
   Quando a memória RAM acaba, sem swap o Linux mata um programa (pode ser o
   seu banco de dados). A swap é um 'transbordo' no disco: mais lenta, mas
   evita isso. Este servidor tem ${ram_mb:-?} MB de RAM. Sugestão: 2G. Se o
   servidor já tiver swap, nada muda."

  ask_yes_no INSTALL_DOCKER "Instalar o Docker?" \
"11/12 DOCKER
   O Docker roda aplicações em 'caixas' separadas (contêineres). É instalado
   do repositório oficial, conferindo a assinatura. Se não vai usar, 'nao'."
  if [[ $INSTALL_DOCKER == sim ]]; then
    ask_yes_no DOCKER_GROUP "Deixar '$ADMIN_USER' usar o Docker sem sudo?" \
"      DOCKER SEM SUDO
   Mais prático (docker ps em vez de sudo docker ps), mas quem usa o Docker
   consegue fazer tudo no servidor. Ou seja: na prática, quem roubar a sua
   chave SSH vira administrador sem precisar da senha do sudo. Num servidor
   pessoal, 'sim' é comum; se quiser o máximo de cuidado, 'nao'."
  else
    DOCKER_GROUP=nao
  fi

  ask_yes_no RUN_LYNIS "Rodar a auditoria Lynis no fim?" \
"12/12 AUDITORIA (LYNIS)
   O Lynis é um programa conhecido que só LÊ o servidor e dá uma nota de 0 a
   100, com sugestões. Leva 1 a 2 minutos. Bom para comparar servidores."

  echo
  if confirm "Quer ver as opções avançadas (fail2ban, logs, tempo do desfazer automático)?" nao; then
    ask FAIL2BAN_MAXRETRY "Tentativas de login erradas antes de bloquear" \
"   FAIL2BAN: quantos erros de login seguidos (em 10 minutos) fazem um
   endereço ser bloqueado."
    ask FAIL2BAN_BANTIME "Tempo de bloqueio" \
"   FAIL2BAN: por quanto tempo o endereço fica bloqueado (30m, 1h, 1d)."
    ask JOURNAL_MAX "Espaço máximo dos logs do sistema" \
"   LOGS: o tamanho máximo que os logs do Ubuntu podem ocupar no disco."
    ask ROLLBACK_MINUTES "Minutos para confirmar o novo login" \
"   DESFAZER AUTOMÁTICO: depois de mudar o SSH e o firewall, você tem este
   tempo para confirmar que consegue entrar. Se não confirmar, as mudanças
   de SSH e firewall voltam sozinhas."
  fi
}

show_answers() {
  local key_text="(pular: usar as chaves que já existem)"
  [[ -n $SSH_KEY ]] && key_text="${SSH_KEY:0:24}...${SSH_KEY: -16}"
  cat <<EOF

Resumo das respostas:
  Conta de administrador ....... $ADMIN_USER
  Chave SSH .................... $key_text
  Nome do servidor ............. ${NEW_HOSTNAME:-(manter $(hostname))}
  Fuso horário ................. $TIMEZONE
  Porta do SSH ................. $SSH_PORT
  Túnel SSH .................... $SSH_TUNNEL
  Portas abertas (além do SSH) . ${PUBLIC_PORTS:-nenhuma}
  Atualizar tudo agora ......... $UPGRADE_NOW
  Reinício automático .......... $AUTO_REBOOT
  Swap ......................... $SWAP_SIZE
  Instalar Docker .............. $INSTALL_DOCKER (sem sudo: $DOCKER_GROUP)
  Auditoria Lynis .............. $RUN_LYNIS
  Avançado ..................... fail2ban $FAIL2BAN_MAXRETRY erros/$FAIL2BAN_BANTIME, logs até $JOURNAL_MAX, desfazer em $ROLLBACK_MINUTES min
EOF
}

# ---------------------------------------------------------------------------
# 1. Sistema
# ---------------------------------------------------------------------------
step_system() {
  section "1. Sistema"
  local id="" version=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id=$(. /etc/os-release && echo "$ID")
    # shellcheck disable=SC1091
    version=$(. /etc/os-release && echo "$VERSION_ID")
  fi
  if [[ $id == ubuntu && $version == 24.04 ]]; then
    ok "Ubuntu $version"
  elif [[ $id == ubuntu ]]; then
    warn "feito e testado para Ubuntu 24.04; este é Ubuntu $version. Confira cada etapa"
  else
    warn "feito e testado para Ubuntu 24.04; este é '$id $version'. Pode não funcionar"
  fi
  if [[ -d /run/systemd/system ]]; then
    ok "systemd rodando"
  else
    fail "o systemd não está rodando (isto é um contêiner?); parando"
    exit 1
  fi
  local free_gb
  free_gb=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
  if ((free_gb >= 5)); then ok "espaço livre no disco: ${free_gb} GB"; else warn "só ${free_gb} GB livres no disco"; fi
}

# ---------------------------------------------------------------------------
# 2. Pacotes
# ---------------------------------------------------------------------------
step_packages() {
  section "2. Programas necessários"
  local -a packages=(ca-certificates curl gnupg ufw fail2ban unattended-upgrades)
  [[ $RUN_LYNIS == sim ]] && packages+=(lynis)
  local -a need=()
  local p
  for p in "${packages[@]}"; do pkg_installed "$p" || need+=("$p"); done
  if ((${#need[@]} == 0)); then
    ok "instalados: ${packages[*]}"
  elif ((!APPLY)); then
    missing "não instalados: ${need[*]}"
  else
    echo "  instalando ${need[*]}..."
    if apt_get update && apt_get install "${need[@]}"; then
      fixed "instalados: ${need[*]}"
    else
      fail "o apt-get não conseguiu instalar: ${need[*]} (veja $APT_LOG)"
    fi
  fi
  if ((APPLY)) && [[ $UPGRADE_NOW == sim ]]; then
    echo "  atualizando o sistema (1 a 5 minutos)..."
    if apt_get update && apt_get upgrade; then fixed "sistema atualizado (apt-get upgrade)"; else fail "apt-get upgrade falhou (veja $APT_LOG)"; fi
  fi
}

# ---------------------------------------------------------------------------
# 3. Relógio e nome
# ---------------------------------------------------------------------------
step_time() {
  section "3. Relógio e nome"
  local tz ntp
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  if [[ $tz == "$TIMEZONE" ]]; then
    ok "fuso horário $TIMEZONE"
  elif ((APPLY)); then
    timedatectl set-timezone "$TIMEZONE" && fixed "fuso horário $tz -> $TIMEZONE"
  else
    missing "fuso horário é '$tz', deveria ser $TIMEZONE"
  fi
  ntp=$(timedatectl show -p NTP --value 2>/dev/null || true)
  if [[ $ntp == yes ]]; then
    ok "relógio acertado pela internet (NTP)"
  elif ((APPLY)); then
    timedatectl set-ntp true && fixed "acerto do relógio pela internet (NTP) ligado"
  else
    missing "acerto do relógio pela internet (NTP) desligado"
  fi
  if [[ -n $NEW_HOSTNAME ]]; then
    if [[ $(hostname) == "$NEW_HOSTNAME" ]]; then
      ok "nome do servidor $NEW_HOSTNAME"
    elif ((APPLY)); then
      hostnamectl set-hostname "$NEW_HOSTNAME"
      grep -q "[[:space:]]$NEW_HOSTNAME\$" /etc/hosts || printf '127.0.1.1 %s\n' "$NEW_HOSTNAME" >>/etc/hosts
      fixed "nome do servidor -> $NEW_HOSTNAME"
    else
      missing "nome do servidor é '$(hostname)', você pediu '$NEW_HOSTNAME'"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 4. Conta de administrador
# ---------------------------------------------------------------------------
step_admin() {
  section "4. Conta de administrador ($ADMIN_USER)"
  if ! getent passwd "$ADMIN_USER" >/dev/null; then
    if ((APPLY)); then
      adduser --disabled-password --gecos "" "$ADMIN_USER" >/dev/null && fixed "conta $ADMIN_USER criada"
    else
      missing "a conta $ADMIN_USER não existe (vai ser criada)"
      return 0
    fi
  else
    ok "a conta $ADMIN_USER existe"
  fi

  if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo; then
    ok "$ADMIN_USER está no grupo sudo (pode administrar)"
  elif ((APPLY)); then
    usermod -aG sudo "$ADMIN_USER" && fixed "$ADMIN_USER colocado no grupo sudo"
  else
    missing "$ADMIN_USER não está no grupo sudo"
  fi

  local home keys_file n source_file=""
  home=$(user_home "$ADMIN_USER")
  keys_file=$home/.ssh/authorized_keys
  n=$(count_keys "$keys_file")
  if [[ -n $SSH_KEY ]] && ! grep -qF "$(awk '{print $2}' <<<"$SSH_KEY")" "$keys_file" 2>/dev/null; then
    if ((APPLY)); then
      install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
      printf '%s\n' "$SSH_KEY" >>"$keys_file"
      fixed "sua chave foi colocada na conta $ADMIN_USER"
    else
      missing "sua chave ainda não está em $keys_file"
    fi
  elif ((n == 0)); then
    # Sem chave: copia a de quem rodou o sudo, ou a que o provedor pôs no root.
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != "$ADMIN_USER" ]] && (($(count_keys "$(user_home "$SUDO_USER")/.ssh/authorized_keys") > 0)); then
      source_file=$(user_home "$SUDO_USER")/.ssh/authorized_keys
    elif (($(count_keys /root/.ssh/authorized_keys) > 0)); then
      source_file=/root/.ssh/authorized_keys
    fi
    if [[ -n $source_file ]]; then
      if ((APPLY)); then
        install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
        grep -E "^[^#]*$KEY_REGEX" "$source_file" >>"$keys_file"
        fixed "chaves copiadas de $source_file para $ADMIN_USER"
      else
        missing "$ADMIN_USER não tem chave SSH; vou copiar as de $source_file"
      fi
    fi
  fi
  if ((APPLY)) && [[ -f $keys_file ]]; then
    chown "$ADMIN_USER:$ADMIN_USER" "$home/.ssh" "$keys_file"
    chmod 700 "$home/.ssh"
    chmod 600 "$keys_file"
  fi
  n=$(count_keys "$keys_file")
  if ((n > 0)); then
    ok "$ADMIN_USER tem $n chave(s) SSH"
  elif ((APPLY)) || [[ -z $source_file && -z $SSH_KEY ]]; then
    warn "$ADMIN_USER NÃO tem chave SSH. A etapa do SSH não vai rodar, para você não ficar trancado. Rode de novo com uma chave"
  fi

  # O sudo pede senha (é a segunda barreira), então a conta precisa de uma.
  local state
  state=$(passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}')
  if [[ $state == P ]]; then
    ok "$ADMIN_USER tem senha (o sudo pede essa senha)"
  elif ((APPLY)) && ((HAS_TTY)); then
    echo "  Escolha a senha que o sudo vai pedir para $ADMIN_USER."
    echo "  Guarde-a num gerenciador de senhas. Ao digitar, nada aparece na tela; é normal."
    if passwd "$ADMIN_USER" </dev/tty; then fixed "senha definida para $ADMIN_USER"; else fail "senha não definida (rode: sudo passwd $ADMIN_USER)"; fi
  elif ((APPLY)); then
    fail "$ADMIN_USER não tem senha; rode agora 'passwd $ADMIN_USER' nesta sessão de root"
  else
    missing "$ADMIN_USER não tem senha (o sudo não funcionaria)"
  fi
}

# ---------------------------------------------------------------------------
# Desfazer automático (rede de segurança)
# Antes de mexer no SSH e no firewall, guarda uma cópia de como estavam e
# agenda um "desfazer" para daqui a ROLLBACK_MINUTES minutos. Se você
# confirmar que consegue entrar, o desfazer é cancelado. Se a conexão cair e
# você não conseguir voltar, ele roda sozinho e devolve o acesso.
# ---------------------------------------------------------------------------
BACKUP_DIR=""

ssh_runtime_reload() {
  # $1 = 1 quando a porta mudou (precisa reabrir a "escuta").
  # No Ubuntu 24.04 o SSH costuma ser iniciado pelo ssh.socket: a porta é
  # lida do sshd_config por um gerador do systemd (daemon-reload) e o socket
  # precisa ser reiniciado. As sessões abertas continuam (KillMode=process).
  if (($1)); then
    systemctl daemon-reload
    if systemctl is-active --quiet ssh.socket; then
      systemctl restart ssh.socket
      systemctl is-active --quiet ssh.service && systemctl restart ssh.service
    else
      systemctl restart ssh.service 2>/dev/null || systemctl restart sshd 2>/dev/null
    fi
  else
    systemctl reload ssh.service 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
}

arm_rollback() {
  ((APPLY)) || return 0
  BACKUP_DIR=$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)
  install -d -m 700 "$BACKUP_DIR"
  [[ -f $SSH_DROPIN ]] && cp -a "$SSH_DROPIN" "$BACKUP_DIR/ssh-dropin"
  [[ -d /etc/ufw ]] && cp -a /etc/ufw "$BACKUP_DIR/ufw"
  local ufw_was_active=nao
  ufw status 2>/dev/null | grep -q '^Status: active' && ufw_was_active=sim
  cat >"$BACKUP_DIR/desfazer.sh" <<EOF
#!/bin/bash
# Criado pelo safe-vps em $(date '+%Y-%m-%d %H:%M'). Devolve o SSH e o
# firewall ao estado de antes, caso ninguém tenha confirmado o novo login.
set -u
if [ -f '$BACKUP_DIR/ssh-dropin' ]; then cp -a '$BACKUP_DIR/ssh-dropin' '$SSH_DROPIN'; else rm -f '$SSH_DROPIN'; fi
if [ -d '$BACKUP_DIR/ufw' ]; then rm -rf /etc/ufw && cp -a '$BACKUP_DIR/ufw' /etc/ufw; fi
systemctl daemon-reload
if systemctl is-active --quiet ssh.socket; then systemctl restart ssh.socket; fi
systemctl restart ssh.service 2>/dev/null || systemctl restart sshd 2>/dev/null
if [ '$ufw_was_active' = sim ]; then ufw reload; else ufw --force disable; fi
rm -f '$PORT_CONFIRMED_FILE'
echo "\$(date '+%Y-%m-%d %H:%M') SSH e firewall desfeitos automaticamente (o novo login não foi confirmado)." >>/var/log/safe-vps-desfeito.log
logger -t safe-vps "SSH e firewall desfeitos automaticamente (o novo login não foi confirmado)"
EOF
  chmod 700 "$BACKUP_DIR/desfazer.sh"
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1
  systemctl reset-failed "$ROLLBACK_UNIT.service" "$ROLLBACK_UNIT.timer" >/dev/null 2>&1
  if systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_MINUTES}min" \
    --description="safe-vps: desfazer SSH e firewall se o login não for confirmado" \
    /bin/bash "$BACKUP_DIR/desfazer.sh"; then
    ok "rede de segurança ligada: cópia em $BACKUP_DIR; desfaz sozinho em $ROLLBACK_MINUTES min se você não confirmar"
  else
    fail "não consegui agendar o desfazer automático; parando antes de mexer no SSH e no firewall"
    exit 1
  fi
}

disarm_rollback() {
  systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1
  systemctl reset-failed "$ROLLBACK_UNIT.service" "$ROLLBACK_UNIT.timer" >/dev/null 2>&1
}

rollback_pending() { systemctl is-active --quiet "$ROLLBACK_UNIT.timer"; }

# ---------------------------------------------------------------------------
# 5. SSH
# ---------------------------------------------------------------------------
# Só os algoritmos que este OpenSSH conhece, de uma lista moderna.
ssh_supported() {
  local kind=$1 a out="" available
  shift
  available=" $(ssh -Q "$kind" 2>/dev/null | tr '\n' ' ') "
  for a in "$@"; do [[ $available == *" $a "* ]] && out+="${out:+,}$a"; done
  printf '%s' "$out"
}

# Portas em que o SSH deve escutar. Na troca de porta, a 22 continua aberta
# até você confirmar que entrou pela nova (arquivo PORT_CONFIRMED_FILE).
ssh_ports() {
  if [[ $SSH_PORT == 22 ]]; then
    echo 22
  elif [[ -f $PORT_CONFIRMED_FILE && $(cat "$PORT_CONFIRMED_FILE") == "$SSH_PORT" ]]; then
    echo "$SSH_PORT"
  else
    echo "22 $SSH_PORT"
  fi
}

ssh_content() {
  local p forwarding=no
  [[ $SSH_TUNNEL == sim ]] && forwarding=local
  echo "# Criado pelo safe-vps. Mudanças feitas aqui à mão são desfeitas na"
  echo "# próxima vez que ele aplicar. Explicação de cada linha: README.md, etapa 5."
  for p in $(ssh_ports); do echo "Port $p"; done
  cat <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AllowUsers $ADMIN_USER
MaxAuthTries 4
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
AllowTcpForwarding $forwarding
AllowAgentForwarding no
X11Forwarding no
PermitUserEnvironment no
LogLevel VERBOSE
KexAlgorithms $(ssh_supported kex mlkem768x25519-sha256 sntrup761x25519-sha512 sntrup761x25519-sha512@openssh.com curve25519-sha256 curve25519-sha256@libssh.org diffie-hellman-group18-sha512 diffie-hellman-group16-sha512)
Ciphers $(ssh_supported cipher chacha20-poly1305@openssh.com aes256-gcm@openssh.com aes128-gcm@openssh.com aes256-ctr aes192-ctr aes128-ctr)
MACs $(ssh_supported mac hmac-sha2-512-etm@openssh.com hmac-sha2-256-etm@openssh.com umac-128-etm@openssh.com)
EOF
}

# O valor que o sshd realmente usa depois de ler todos os arquivos.
ssh_effective() { sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print }'; }

port_listening() { [[ -n $(ss -Htln "sport = :$1" 2>/dev/null) ]]; }

# No modo conferir: a etapa 4 vai colocar uma chave na conta?
key_will_be_added() {
  [[ -n $SSH_KEY ]] && return 0
  [[ -n ${SUDO_USER:-} && $SUDO_USER != "$ADMIN_USER" ]] && (($(count_keys "$(user_home "$SUDO_USER")/.ssh/authorized_keys") > 0)) && return 0
  (($(count_keys /root/.ssh/authorized_keys) > 0))
}

step_ssh() {
  section "5. SSH (como você entra no servidor)"
  if ! has sshd; then
    fail "sshd não encontrado"
    return 0
  fi
  # O sshd só consegue testar as configurações se esta pasta existir. No
  # Ubuntu 24.04 ela é criada quando chega a primeira conexão; criamos antes.
  [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
    fail "/etc/ssh/sshd_config não lê a pasta sshd_config.d/; não vou mexer no SSH"
    return 0
  fi
  # Proteção contra ficar trancado: nunca desligar a senha de uma conta sem chave.
  if (($(count_keys "$(user_home "$ADMIN_USER")/.ssh/authorized_keys") == 0)); then
    if ((!APPLY)) && key_will_be_added; then
      missing "configurações do SSH (depois que a chave estiver na conta $ADMIN_USER)"
    else
      warn "pulado: $ADMIN_USER não tem chave SSH (desligar a senha agora trancaria você do lado de fora)"
    fi
    return 0
  fi

  local content previous_ports
  content=$(ssh_content)
  previous_ports=$(ssh_effective port | sort -n | paste -sd ' ')
  if ! want_file "$SSH_DROPIN" 0644 "$content" "configurações do SSH"; then
    # Acabou de gravar: testa antes de valer e desfaz se algo estiver errado.
    local rollback=0 out key want got wanted_ports port_changed=0
    wanted_ports=$(ssh_ports | tr ' ' '\n' | sort -n | paste -sd ' ')
    if ! out=$(sshd -t 2>&1); then
      fail "o sshd recusou as novas configurações: $out"
      rollback=1
    else
      local forwarding=no
      [[ $SSH_TUNNEL == sim ]] && forwarding=local
      for key in permitrootlogin:no passwordauthentication:no kbdinteractiveauthentication:no \
        allowusers:"$ADMIN_USER" maxauthtries:4 allowtcpforwarding:"$forwarding"; do
        want=${key#*:}
        got=$(ssh_effective "${key%%:*}")
        if [[ $got != "$want" ]]; then
          fail "outro arquivo do SSH tem prioridade: ${key%%:*} é '$got', esperado '$want' (veja /etc/ssh/sshd_config.d/)"
          rollback=1
        fi
      done
      got=$(ssh_effective port | sort -n | paste -sd ' ')
      if [[ $got != "$wanted_ports" ]]; then
        fail "o SSH escutaria nas portas '$got', esperado '$wanted_ports' (há 'Port' em outro arquivo?)"
        rollback=1
      fi
    fi
    if ((!rollback)); then
      [[ $previous_ports != "$wanted_ports" ]] && port_changed=1
      ssh_runtime_reload "$port_changed"
      sleep 2
      local p
      for p in $wanted_ports; do
        if ! port_listening "$p"; then
          fail "depois de recarregar, o SSH não está escutando na porta $p"
          rollback=1
        fi
      done
    fi
    if ((rollback)); then
      if [[ -f $BACKUP_DIR/ssh-dropin ]]; then cp -a "$BACKUP_DIR/ssh-dropin" "$SSH_DROPIN"; else rm -f "$SSH_DROPIN"; fi
      ssh_runtime_reload 1
      warn "configurações do SSH devolvidas como estavam"
      return 0
    fi
    fixed "SSH recarregado com as novas configurações (portas: $wanted_ports)"
    SSH_CHANGED=1
  fi

  # Confere o que está valendo de verdade.
  local v
  for v in permitrootlogin passwordauthentication; do
    if [[ $(ssh_effective "$v") == no ]]; then ok "$v no (valendo)"; else missing "$v está '$(ssh_effective "$v")'"; fi
  done
  if [[ $SSH_PORT != 22 && $(ssh_ports) == "22 $SSH_PORT" ]]; then
    warn "a porta 22 continua aberta junto com a $SSH_PORT até você confirmar o login pela nova"
  fi
}

# ---------------------------------------------------------------------------
# 6. Firewall (ufw)
# ---------------------------------------------------------------------------
ufw_do() {
  # shellcheck disable=SC2068
  ufw $@ >/dev/null && FIREWALL_CHANGED=1
}

step_firewall() {
  section "6. Firewall (ufw)"
  if ! has ufw; then
    missing "ufw não instalado (a etapa 2 instala)"
    return 0
  fi
  local added status p ports
  added=$(ufw show added 2>/dev/null || true)
  status=$(ufw status verbose 2>/dev/null || true)

  # Sem chave, a etapa do SSH não rodou: o SSH continua na porta de antes.
  if [[ -f $SSH_DROPIN ]]; then ports=$(ssh_ports); else ports=22; fi

  # SSH primeiro, para que ligar o firewall nunca corte esta sessão.
  # "limit" = mais de 6 conexões novas em 30 segundos do mesmo endereço são
  # recusadas por um tempo (segura enxurradas de tentativas).
  for p in $ports; do
    if grep -qxF "ufw limit $p/tcp" <<<"$added"; then
      ok "SSH ($p) aberto com limite contra enxurrada"
    elif ((APPLY)); then
      ufw_do limit "$p/tcp" && fixed "SSH ($p) aberto com limite contra enxurrada"
    else
      missing "SSH ($p) sem regra de limite no firewall"
    fi
  done
  # Uma regra antiga "allow" para o SSH ganharia do limite.
  local old
  for p in $ports; do
    for old in "allow $p/tcp" "allow $p"; do
      if grep -qxF "ufw $old" <<<"$added"; then
        if ((APPLY)); then
          ufw_do delete "$old" && fixed "regra antiga '$old' removida (a regra de limite substitui)"
        else
          missing "regra antiga '$old' (ganha da regra de limite)"
        fi
      fi
    done
  done
  if [[ $ports == 22 ]] && grep -qxF "ufw allow OpenSSH" <<<"$added"; then
    if ((APPLY)); then ufw_do delete allow OpenSSH && fixed "regra antiga 'allow OpenSSH' removida"; else missing "regra antiga 'allow OpenSSH' (ganha da regra de limite)"; fi
  fi
  # A porta 22 depois de confirmada a troca: fecha.
  if [[ " $ports " != *" 22 "* ]] && grep -qxF "ufw limit 22/tcp" <<<"$added"; then
    if ((APPLY)); then ufw_do delete limit 22/tcp && fixed "porta 22 fechada (você já entra pela $SSH_PORT)"; else missing "porta 22 ainda aberta no firewall"; fi
  fi

  for p in $PUBLIC_PORTS; do
    if grep -qxF "ufw allow $p" <<<"$added"; then
      ok "porta $p aberta"
    elif ((APPLY)); then
      ufw_do allow "$p" && fixed "porta $p aberta"
    else
      missing "porta $p não está aberta"
    fi
  done
  # Portas abertas que não estão na sua lista.
  local rule
  while read -r rule; do
    [[ $rule =~ ^ufw\ allow\ ([0-9]+/(tcp|udp))$ ]] || continue
    [[ " $PUBLIC_PORTS " == *" ${BASH_REMATCH[1]} "* ]] && continue
    warn "a porta ${BASH_REMATCH[1]} está aberta no firewall mas não está na sua lista (não mexi; para fechar: sudo ufw delete allow ${BASH_REMATCH[1]})"
  done <<<"$added"

  if grep -q 'Default: deny (incoming), allow (outgoing)' <<<"$status"; then
    ok "padrão: bloquear entrada, liberar saída"
  elif ((APPLY)); then
    ufw_do default deny incoming && ufw_do default allow outgoing && fixed "padrão: bloquear entrada, liberar saída"
  else
    missing "o padrão não é 'bloquear entrada, liberar saída'"
  fi

  if grep -q '^Status: active' <<<"$status"; then
    ok "firewall ligado"
  elif ((APPLY)); then
    ufw_do --force enable && fixed "firewall ligado"
  else
    missing "firewall desligado"
  fi
}

# ---------------------------------------------------------------------------
# 7. fail2ban
# ---------------------------------------------------------------------------
step_fail2ban() {
  section "7. fail2ban (bloqueia quem erra o login muitas vezes)"
  if ! has fail2ban-client; then
    missing "fail2ban não instalado (a etapa 2 instala)"
    return 0
  fi
  local ports content
  if [[ -f $SSH_DROPIN ]]; then ports=$(ssh_ports | tr ' ' ','); else ports=22; fi
  content="# Criado pelo safe-vps. Explicação: README.md, etapa 7.
# $FAIL2BAN_MAXRETRY logins errados em 10 minutos = o endereço fica bloqueado por $FAIL2BAN_BANTIME.
[sshd]
enabled = true
port = $ports
backend = systemd
maxretry = $FAIL2BAN_MAXRETRY
findtime = 10m
bantime = $FAIL2BAN_BANTIME"
  if ! want_file "$FAIL2BAN_JAIL" 0644 "$content" "fail2ban vigiando o SSH"; then
    if fail2ban-client -t >/dev/null 2>&1; then
      systemctl enable fail2ban >/dev/null 2>&1
      systemctl restart fail2ban && fixed "fail2ban reiniciado"
    else
      rm -f "$FAIL2BAN_JAIL"
      fail "o fail2ban recusou as configurações; arquivo removido"
    fi
  fi
  if systemctl is-active --quiet fail2ban; then
    ok "fail2ban rodando"
  elif ((APPLY)); then
    systemctl enable --now fail2ban && fixed "fail2ban ligado"
  else
    missing "fail2ban não está rodando"
  fi
}

# ---------------------------------------------------------------------------
# 8. Atualizações automáticas de segurança
# ---------------------------------------------------------------------------
step_updates() {
  section "8. Atualizações automáticas de segurança"
  # O 50unattended-upgrades do próprio Ubuntu já limita às correções de segurança.
  want_file "$UPGRADES_FILE" 0644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' "atualizações de segurança todo dia" || true
  local content
  if [[ $AUTO_REBOOT == nao ]]; then
    content='// Criado pelo safe-vps. Nunca reiniciar sozinho; o script avisa quando há reinício pendente.
Unattended-Upgrade::Automatic-Reboot "false";'
    want_file "$UPGRADES_REBOOT_FILE" 0644 "$content" "sem reinício automático (você reinicia quando quiser)" || true
  else
    content="// Criado pelo safe-vps. Reinicia sozinho às $AUTO_REBOOT, só quando uma atualização pedir.
Unattended-Upgrade::Automatic-Reboot \"true\";
Unattended-Upgrade::Automatic-Reboot-Time \"$AUTO_REBOOT\";"
    want_file "$UPGRADES_REBOOT_FILE" 0644 "$content" "reinício automático às $AUTO_REBOOT quando preciso" || true
  fi
  if [[ -f /var/run/reboot-required ]]; then
    warn "há um reinício pendente para terminar atualizações (sudo reboot, num horário calmo)"
  fi
}

# ---------------------------------------------------------------------------
# 9. Proteções do kernel e da rede (sysctl)
# Lista baseada na do Gaia-harden. Nenhuma mexe em net.ipv4.ip_forward,
# que o Docker precisa.
# ---------------------------------------------------------------------------
step_sysctl() {
  section "9. Proteções do kernel e da rede"
  local content
  content=$(cat <<'EOF'
# Criado pelo safe-vps. Explicação de cada grupo: README.md, etapa 9.
# Rede: descartar pacotes com remetente falso, ignorar "redirecionamentos"
# (alguém mandando o servidor enviar tráfego para outro lugar), registrar
# pacotes estranhos.
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Continuar respondendo durante uma enxurrada de conexões pela metade (SYN flood).
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
# Esconder detalhes do kernel que ajudam um atacante; bloquear truques entre programas.
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.randomize_va_space = 2
kernel.sysrq = 0
# Arquivos: bloquear truques com atalhos em pastas compartilhadas; sem
# cópias de memória de programas que rodam com permissões extras.
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
EOF
)
  if ! want_file "$SYSCTL_FILE" 0644 "$content" "proteções do kernel e da rede"; then
    if sysctl -e -q -p "$SYSCTL_FILE"; then fixed "proteções valendo agora (e depois de cada reinício)"; else fail "o sysctl não conseguiu aplicar $SYSCTL_FILE"; fi
  fi
}

# ---------------------------------------------------------------------------
# 10. Logs do sistema (journald)
# ---------------------------------------------------------------------------
step_journald() {
  section "10. Logs do sistema"
  if ! want_file "$JOURNALD_FILE" 0644 "# Criado pelo safe-vps. Explicação: README.md, etapa 10.
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=$JOURNAL_MAX" "logs guardados depois de reiniciar, no máximo $JOURNAL_MAX"; then
    systemctl restart systemd-journald && fixed "journald reiniciado"
  fi
}

# ---------------------------------------------------------------------------
# 11. Swap
# ---------------------------------------------------------------------------
step_swap() {
  section "11. Swap (memória extra no disco)"
  if [[ $SWAP_SIZE == 0 ]]; then
    ok "pulado (você escolheu sem swap)"
    return 0
  fi
  if [[ -n $(swapon --show --noheadings 2>/dev/null) ]]; then
    ok "swap ligada ($(swapon --show --noheadings | awk '{print $1" "$3}' | paste -sd ' '))"
  elif ((APPLY)); then
    if [[ -e /swapfile ]]; then
      fail "/swapfile já existe mas não está em uso; confira à mão (sudo swapon /swapfile)"
    elif fallocate -l "$SWAP_SIZE" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
      fixed "swap de $SWAP_SIZE criada (/swapfile)"
    else
      rm -f /swapfile
      fail "não consegui criar /swapfile (alguns tipos de VPS, como OpenVZ/LXC, não permitem swap; aí responda 0)"
    fi
  else
    missing "sem swap (vai criar $SWAP_SIZE)"
  fi
  # Usar a swap só quando faltar memória de verdade (o padrão é 60).
  want_file "$SWAPPINESS_FILE" 0644 'vm.swappiness = 10' "swap só quando faltar memória de verdade" ||
    sysctl -q -p "$SWAPPINESS_FILE"
}

# ---------------------------------------------------------------------------
# 12. Serviços de rede sem uso
# ---------------------------------------------------------------------------
step_services() {
  section "12. Serviços de rede sem uso"
  local unit found=0
  for unit in rpcbind.socket rpcbind.service avahi-daemon.socket avahi-daemon.service cups.socket cups.service cups-browsed.service; do
    if systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null; then
      found=1
      if ((APPLY)); then systemctl disable --now "$unit" >/dev/null 2>&1 && fixed "$unit desligado"; else missing "$unit está ligado (serviço que um servidor não usa)"; fi
    fi
  done
  ((found)) || ok "nenhum de rpcbind, avahi, cups está ligado"
  if has aa-status; then
    if aa-status --enabled 2>/dev/null; then ok "AppArmor ligado (limita o que cada programa pode tocar)"; else warn "AppArmor está desligado"; fi
  fi
}

# ---------------------------------------------------------------------------
# 13. Docker
# ---------------------------------------------------------------------------
step_docker() {
  section "13. Docker"
  if [[ $INSTALL_DOCKER != sim ]]; then
    ok "pulado (você escolheu não instalar)"
    return 0
  fi
  if pkg_installed docker-ce; then
    ok "Docker instalado do repositório oficial ($(docker --version 2>/dev/null | cut -d, -f1))"
  elif pkg_installed docker.io; then
    warn "Docker instalado pelo pacote do Ubuntu (docker.io), não o oficial. Funciona; não mexi"
  elif ((!APPLY)); then
    missing "Docker não instalado"
  else
    local key=/etc/apt/keyrings/docker.asc tmp fpr codename arch
    install -d -m 0755 /etc/apt/keyrings
    tmp=$(mktemp)
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$tmp"; then
      fail "não consegui baixar a chave do Docker"
      rm -f "$tmp"
      return 0
    fi
    fpr=$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
    if [[ $fpr != "$DOCKER_KEY_FINGERPRINT" ]]; then
      fail "a chave do Docker tem uma impressão digital inesperada ($fpr); NÃO instalei"
      rm -f "$tmp"
      return 0
    fi
    install -m 0644 "$tmp" "$key"
    rm -f "$tmp"
    # shellcheck disable=SC1091
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    arch=$(dpkg --print-architecture)
    echo "deb [arch=$arch signed-by=$key] https://download.docker.com/linux/ubuntu $codename stable" >/etc/apt/sources.list.d/docker.list
    echo "  instalando o Docker (1 a 3 minutos)..."
    if apt_get update && apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      systemctl enable --now docker >/dev/null 2>&1
      fixed "Docker instalado (repositório oficial, chave conferida)"
    else
      fail "o apt-get não conseguiu instalar o Docker (veja $APT_LOG)"
      return 0
    fi
  fi
  if getent group docker >/dev/null && getent passwd "$ADMIN_USER" >/dev/null; then
    local in_group=0
    id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx docker && in_group=1
    if [[ $DOCKER_GROUP == sim ]]; then
      if ((in_group)); then
        ok "$ADMIN_USER está no grupo docker (usa o docker sem sudo)"
      elif ((APPLY)); then
        usermod -aG docker "$ADMIN_USER" && fixed "$ADMIN_USER colocado no grupo docker (vale a partir do próximo login)"
      else
        missing "$ADMIN_USER não está no grupo docker"
      fi
    elif ((in_group)); then
      warn "$ADMIN_USER está no grupo docker, mas você escolheu 'nao' (não tirei; para tirar: sudo gpasswd -d $ADMIN_USER docker)"
    else
      ok "$ADMIN_USER usa o docker com sudo (como você escolheu)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# 14. O que está aberto para a internet
# ---------------------------------------------------------------------------
step_ports() {
  section "14. Portas abertas para a internet"
  # O Docker abre as portas dele SEM passar pelo ufw, então aqui olhamos o
  # que está escutando de verdade, e não só as regras do firewall.
  local expected addr port proto unexpected=0 p
  expected=" $(ssh_ports) "
  for p in $PUBLIC_PORTS; do expected+="${p%/*} "; done
  while read -r proto addr; do
    port=${addr##*:}
    case $addr in
      127.* | \[::1\]:* | *%lo:*) continue ;;
    esac
    case $port in
      68 | 546) continue ;; # DHCP: o servidor pedindo o endereço ao provedor
    esac
    if [[ $expected == *" $port "* ]]; then
      ok "porta $port ($proto) escutando em $addr (esperado)"
    else
      warn "porta $port ($proto) escutando em $addr e NÃO está na sua lista. Se for um contêiner do Docker, ele fica aberto mesmo com o firewall (veja README, etapa 14)"
      unexpected=1
    fi
  done < <(ss -Htuln 2>/dev/null | awk '{print $1, $5}' | sort -u)
  ((unexpected)) || ok "nada inesperado aberto"
}

# ---------------------------------------------------------------------------
# 15. Auditoria Lynis (só lê, dá uma nota)
# ---------------------------------------------------------------------------
step_lynis() {
  section "15. Auditoria Lynis (só lê; leva 1 a 2 minutos)"
  if [[ $RUN_LYNIS != sim ]]; then
    ok "pulado (você escolheu não rodar)"
    return 0
  fi
  if ! has lynis; then
    missing "lynis não instalado (a etapa 2 instala)"
    return 0
  fi
  lynis audit system --quiet --no-colors --logfile /var/log/lynis.log --report-file /var/log/lynis-report.dat >/dev/null 2>&1 || true
  local index
  index=$(awk -F= '$1 == "hardening_index" { print $2 }' /var/log/lynis-report.dat 2>/dev/null)
  if [[ -n $index ]]; then
    ok "nota do Lynis: $index de 100. Sugestões: sudo grep '^suggestion' /var/log/lynis-report.dat"
  else
    warn "o Lynis não deu nota; veja /var/log/lynis.log"
  fi
}

# ---------------------------------------------------------------------------
run_steps() {
  MISSING=0
  FAILED=0
  step_system
  step_packages
  step_time
  step_admin
  if ((APPLY)); then
    section "Rede de segurança"
    arm_rollback
  fi
  step_ssh
  step_firewall
  step_fail2ban
  step_updates
  step_sysctl
  step_journald
  step_swap
  step_services
  step_docker
  step_ports
}

server_address() { hostname -I 2>/dev/null | awk '{print $1}'; }

# Depois de mudar SSH ou firewall: pede para testar um login NOVO e confirmar.
confirm_login() {
  local port addr deadline answer
  port=$SSH_PORT
  addr=$(server_address)
  deadline=$(date -d "+$ROLLBACK_MINUTES min" '+%H:%M')
  cat <<EOF

================================================================
  IMPORTANTE: NÃO FECHE ESTA JANELA.
  O SSH e/ou o firewall mudaram. Agora teste se você consegue entrar:

  1. No seu computador, abra uma janela NOVA do terminal.
  2. Digite:   ssh -p $port $ADMIN_USER@${addr:-<endereço do servidor>}
  3. Já dentro, digite:   sudo whoami   (deve responder: root)

  Se funcionou, volte AQUI e digite sim.
  Se você não confirmar até $deadline, o SSH e o firewall voltam sozinhos
  a como estavam antes, para você não ficar trancado do lado de fora.
================================================================
EOF
  if ((!HAS_TTY)); then
    echo "  Sem teclado nesta sessão: depois de testar, confirme com"
    echo "  sudo bash $0 --confirmar"
    return 0
  fi
  while true; do
    read -r -p "> Conseguiu entrar pela janela nova? (sim / nao) " answer </dev/tty || return 0
    if is_yes "$answer"; then
      finish_confirmation
      return 0
    fi
    if [[ ${answer,,} =~ ^(n|nao|não|no)$ ]]; then
      echo "  Tudo bem. Tente de novo na outra janela; o manual (MANUAL.md, 'Problemas')"
      echo "  explica os erros mais comuns. Se não der, não faça nada: às $deadline"
      echo "  tudo volta sozinho. Você pode responder aqui de novo."
    fi
  done
}

finish_confirmation() {
  disarm_rollback
  echo "  [ok]       desfazer automático cancelado; as mudanças ficam."
  if [[ $SSH_PORT != 22 && ! ( -f $PORT_CONFIRMED_FILE && $(cat "$PORT_CONFIRMED_FILE") == "$SSH_PORT" ) ]]; then
    install -d -m 700 "$STATE_DIR"
    echo "$SSH_PORT" >"$PORT_CONFIRMED_FILE"
    echo "  Você entrou pela porta $SSH_PORT, então agora fecho a porta 22:"
    APPLY=1
    step_ssh
    step_firewall
    step_fail2ban
    disarm_rollback
  fi
}

main() {
  echo "safe-vps $VERSION: procedimento padrão de segurança para VPS Ubuntu."

  if [[ $MODE == confirm ]]; then
    [[ -f $ANSWERS_FILE ]] || { echo "Não há respostas salvas em $ANSWERS_FILE; nada para confirmar." >&2; exit 1; }
    load_answers "$ANSWERS_FILE"
    validate_all || exit 2
    if ! rollback_pending && [[ $SSH_PORT == 22 || -f $PORT_CONFIRMED_FILE ]]; then
      echo "Não há nada esperando confirmação."
      exit 0
    fi
    finish_confirmation
    exit 0
  fi

  # 1) Respostas
  local asked=0
  if [[ -n $ANSWERS_FROM ]]; then
    load_answers "$ANSWERS_FROM"
  elif [[ -f $ANSWERS_FILE ]] && ((!REASK)); then
    load_answers "$ANSWERS_FILE"
    if ((HAS_TTY)); then
      show_answers
      echo
      if ! confirm "Encontrei as respostas da última vez (acima). Usar as mesmas?" sim; then
        ask_all
        asked=1
      fi
    fi
  elif ((HAS_TTY)); then
    ask_all
    asked=1
  else
    echo "Sem teclado e sem respostas: rode numa janela de terminal, ou use --respostas ARQUIVO." >&2
    exit 2
  fi
  validate_all || exit 2
  while ((asked)); do
    show_answers
    echo
    if confirm "Está tudo certo?" sim; then break; fi
    ask_all
    validate_all || exit 2
  done

  # 2) Conferência (não muda nada)
  echo
  echo "################ PARTE 1: CONFERINDO (nada é mudado) ################"
  APPLY=0
  run_steps
  local to_fix=$MISSING
  section "Resultado da conferência"
  echo "  Itens a mudar: $to_fix. Problemas: $FAILED."

  if [[ $MODE == check ]]; then
    [[ $RUN_LYNIS == sim ]] && step_lynis
    ((to_fix == 0)) || echo "  Para mudar: sudo bash $0"
    exit 0
  fi
  if ((to_fix == 0)); then
    echo "  Está tudo certo; nada a mudar."
    [[ -n $ANSWERS_FROM ]] || save_answers
    [[ $RUN_LYNIS == sim ]] && step_lynis
    exit 0
  fi
  if [[ $MODE != apply ]]; then
    if ((!HAS_TTY)); then
      echo "  Sem teclado para confirmar. Para aplicar: sudo bash $0 --aplicar"
      exit 0
    fi
    echo
    echo "  Os itens [falta] acima serão mudados. Leia-os com calma."
    if ! confirm "Posso aplicar essas mudanças agora?" nao; then
      echo "  Nada foi mudado."
      exit 0
    fi
  fi

  # 3) Aplicação
  echo
  echo "################ PARTE 2: APLICANDO ################"
  echo "  Mantenha ESTA janela aberta até o fim."
  save_answers
  APPLY=1
  run_steps

  if ((SSH_CHANGED || FIREWALL_CHANGED)); then
    confirm_login
  else
    disarm_rollback
  fi

  [[ $RUN_LYNIS == sim ]] && step_lynis

  section "Resumo"
  echo "  Problemas: $FAILED."
  echo "  Respostas salvas em $ANSWERS_FILE (usadas da próxima vez)."
  rollback_pending && echo "  ATENÇÃO: o desfazer automático ainda está agendado. Depois de testar o login: sudo bash $0 --confirmar"
  [[ -f /var/run/reboot-required ]] && echo "  Há um reinício pendente para terminar as atualizações: sudo reboot (num horário calmo)."
  echo "  Para conferir tudo de novo a qualquer hora: sudo bash $0 --conferir"
  ((FAILED == 0))
}

main
