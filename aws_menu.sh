#!/usr/bin/env bash
set -euo pipefail

AWS_REGION_CACHE="/tmp/aws_regions.cache"
AWS_AMI_CACHE="/tmp/aws_ami.cache"
CACHE_TTL=86400 # 24h

DEFAULT_INSTANCE_TYPE="t2.micro"
DEFAULT_KEY_NAME="simplevpn-key"
DEFAULT_SG_NAME="SimpleVPN-SG"

BOT_TOKEN_DEFAULT="PUT_YOUR_TELEGRAM_BOT_TOKEN_HERE"
OUTLINE_API_URL_DEFAULT="https://IP:9090/xxxxxxxxxxxxxxxxxx/"

pause() {
  read -rp "Натисни Enter, щоб продовжити…"
}

require_aws() {
  if ! command -v aws &>/dev/null; then
    echo "❌ AWS CLI не встановлено. Встанови: apt-get install -y awscli (або pkg install awscli)"
    exit 1
  fi
}

now_ts() { date +%s; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

get_regions() {
  if [[ -f "$AWS_REGION_CACHE" && $(( $(now_ts) - $(file_mtime "$AWS_REGION_CACHE") )) -lt $CACHE_TTL ]]; then
    IFS=$'\n' mapfile -t REGIONS < "$AWS_REGION_CACHE"
  else
    mapfile -t REGIONS < <(aws ec2 describe-regions --query "Regions[*].RegionName" --output text | tr '\t' '\n' | sort)
    printf "%s\n" "${REGIONS[@]}" > "$AWS_REGION_CACHE"
  fi
}

select_region() {
  get_regions
  echo "=== Обери регіон ==="
  local i=1
  for r in "${REGIONS[@]}"; do
    printf "%2d) %s\n" "$i" "$r"
    ((i++))
  done
  local choice
  while true; do
    read -rp "Номер: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#REGIONS[@]} )); then
      REGION="${REGIONS[$((choice-1))]}"
      break
    else
      echo "Невірний вибір."
    fi
  done
  echo "✅ Обрано регіон: $REGION"
}

get_latest_ubuntu_ami() {
  local region="$1"
  if [[ -f "$AWS_AMI_CACHE" && $(( $(now_ts) - $(file_mtime "$AWS_AMI_CACHE") )) -lt $CACHE_TTL ]]; then
    AMI_ID=$(awk -v r="$region" '$1==r{print $2}' "$AWS_AMI_CACHE" || true)
  else
    : > "$AWS_AMI_CACHE"
  fi
  if [[ -z "${AMI_ID:-}" ]]; then
    AMI_ID=$(aws ec2 describe-images \
      --owners 099720109477 \
      --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-22.04-amd64-server-*" \
      --query 'Images[*].[ImageId,CreationDate]' \
      --region "$region" \
      --output text | sort -k2 -r | head -n1 | cut -f1)
    echo "$region $AMI_ID" >> "$AWS_AMI_CACHE"
  fi
  echo "$AMI_ID"
}

ensure_keypair() {
  local region="$1" key_name="$2"
  if ! aws ec2 describe-key-pairs --key-names "$key_name" --region "$region" &>/dev/null; then
    echo "🔐 Створюю key-pair: $key_name"
    aws ec2 create-key-pair --key-name "$key_name" --region "$region" \
      --query 'KeyMaterial' --output text > "${key_name}.pem"
    chmod 400 "${key_name}.pem"
    echo "✅ Збережено у: ${key_name}.pem"
  else
    echo "🔑 Key-pair $key_name вже існує (region: $region)"
    if [[ ! -f "${key_name}.pem" ]]; then
      echo "⚠ Локального файлу ${key_name}.pem немає. Створи новий key-pair з іншим ім'ям або підклади файл."
    fi
  fi
}

ensure_sg() {
  local region="$1" sg_name="$2"
  local sg_id
  sg_id=$(aws ec2 describe-security-groups --region "$region" \
    --query "SecurityGroups[?GroupName=='$sg_name'].GroupId" --output text 2>/dev/null || true)
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    echo "🛡 Створюю security group: $sg_name"
    sg_id=$(aws ec2 create-security-group --group-name "$sg_name" \
      --description "SimpleVPN SG" --region "$region" --output text)
    for p in 22 80 443 9090 51820; do
      aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg_id" \
        --protocol tcp --port "$p" --cidr 0.0.0.0/0 >/dev/null
    done
    # WireGuard UDP 51820
    aws ec2 authorize-security-group-ingress --region "$region" --group-id "$sg_id" \
      --protocol udp --port 51820 --cidr 0.0.0.0/0 >/dev/null
    echo "✅ SG створено: $sg_id"
  else
    echo "🛡 SG існує: $sg_id"
  fi
  echo "$sg_id"
}

gen_cloud_init() {
  local bot_token="$1"
  local outline_api="$2"
  cat <<CLOUD
#cloud-config
package_update: true
package_upgrade: true
packages:
  - git
  - python3
  - python3-pip
  - ufw
runcmd:
  - ufw allow 22
  - ufw allow 80
  - ufw allow 443
  - ufw allow 9090
  - ufw allow 51820/tcp
  - ufw allow 51820/udp
  - ufw --force enable
  - cd /opt && git clone -b dev https://github.com/Redrock453/SimpleVPN.git || true
  - cd /opt/SimpleVPN/bot && pip3 install -r requirements.txt
  - bash -c "echo \"TOKEN='$bot_token'\" > /opt/SimpleVPN/bot/config.py"
  - bash -c "echo \"OUTLINE_API_URL='$outline_api'\" >> /opt/SimpleVPN/bot/config.py"
  - nohup python3 /opt/SimpleVPN/bot/client_bot.py >/var/log/simplevpn_bot.log 2>&1 &
CLOUD
}

create_instance() {
  select_region

  read -rp "Вкажи тип інстанса [$DEFAULT_INSTANCE_TYPE]: " INSTANCE_TYPE
  INSTANCE_TYPE=${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}

  read -rp "Ім'я ключа [$DEFAULT_KEY_NAME]: " KEY_NAME
  KEY_NAME=${KEY_NAME:-$DEFAULT_KEY_NAME}

  read -rp "Ім'я security group [$DEFAULT_SG_NAME]: " SG_NAME
  SG_NAME=${SG_NAME:-$DEFAULT_SG_NAME}

  read -rp "BOT_TOKEN (Telegram) [$BOT_TOKEN_DEFAULT]: " BOT_TOKEN
  BOT_TOKEN=${BOT_TOKEN:-$BOT_TOKEN_DEFAULT}

  read -rp "OUTLINE_API_URL [$OUTLINE_API_URL_DEFAULT]: " OUTLINE_API_URL
  OUTLINE_API_URL=${OUTLINE_API_URL:-$OUTLINE_API_URL_DEFAULT}

  AMI_ID=$(get_latest_ubuntu_ami "$REGION")
  echo "✅ AMI: $AMI_ID"

  ensure_keypair "$REGION" "$KEY_NAME"
  SG_ID=$(ensure_sg "$REGION" "$SG_NAME")

  echo "🧩 Генерую cloud-init user-data…"
  USER_DATA_FILE=$(mktemp)
  gen_cloud_init "$BOT_TOKEN" "$OUTLINE_API_URL" > "$USER_DATA_FILE"

  echo "🚀 Запуск інстанса…"
  aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --count 1 \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --region "$REGION" \
    --user-data "file://$USER_DATA_FILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=SimpleVPN}]" \
    --output table

  echo "⏳ Чекаю 15 сек..."
  sleep 15

  IP=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=SimpleVPN" "Name=instance-state-name,Values=pending,running" \
    --query "Reservations[*].Instances[*].PublicIpAddress" --output text | head -n1)

  ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=SimpleVPN" "Name=instance-state-name,Values=pending,running" \
    --query "Reservations[*].Instances[*].InstanceId" --output text | head -n1)

  echo "✅ Інстанс: $ID"
  echo "🌐 IP: $IP"
  echo "🔑 ssh -i ${KEY_NAME}.pem ubuntu@$IP"
  rm -f "$USER_DATA_FILE"
}

list_instances_all_regions() {
  get_regions
  echo "== Список інстансів по всіх регіонах =="
  for r in "${REGIONS[@]}"; do
    echo "---- $r ----"
    aws ec2 describe-instances --region "$r" \
      --query "Reservations[*].Instances[*].[InstanceId,State.Name,PublicIpAddress,Tags[?Key=='Name'].Value|[0]]" \
      --output table || true
  done
}

stop_instance() {
  select_region
  read -rp "Введи InstanceId: " IID
  aws ec2 stop-instances --instance-ids "$IID" --region "$REGION" --output table
}

terminate_instance() {
  select_region
  read -rp "Введи InstanceId: " IID
  aws ec2 terminate-instances --instance-ids "$IID" --region "$REGION" --output table
}

check_port() {
  read -rp "IP: " IP
  read -rp "Порт: " PORT
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/$IP/$PORT" 2>/dev/null \
    && echo "✅ $IP:$PORT відкритий" \
    || echo "❌ $IP:$PORT закритий/недоступний"
}

main_menu() {
  require_aws
  while true; do
    clear
    echo "=== AWS Меню ==="
    echo "1) Показати список інстансів (всі регіони)"
    echo "2) Створити інстанс Ubuntu 22.04 (+cloud-init SimpleVPN)"
    echo "3) Зупинити інстанс"
    echo "4) Видалити інстанс"
    echo "5) Перевірити порт"
    echo "0) Вихід"
    read -rp "Вибери дію: " a
    case "$a" in
      1) list_instances_all_regions; pause ;;
      2) create_instance; pause ;;
      3) stop_instance; pause ;;
      4) terminate_instance; pause ;;
      5) check_port; pause ;;
      0) exit 0 ;;
      *) echo "Невірний вибір"; pause ;;
    esac
  done
}

main_menu
