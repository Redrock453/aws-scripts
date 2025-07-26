#!/bin/bash

# 🔧 Основні налаштування
default_branch="main"

# ✅ Запит назви нової гілки
read -p "🔧 Введи назву гілки (наприклад: feature/login-api): " branch_name

# Якщо гілка існує — переходимо, інакше створюємо
if git show-ref --verify --quiet "refs/heads/$branch_name"; then
  echo "🔁 Перехід на існуючу гілку $branch_name"
  git checkout "$branch_name"
else
  echo "🌱 Створення нової гілки $branch_name"
  git checkout -b "$branch_name"
fi

# Визначаємо шаблон
if [[ "$branch_name" == feature/* ]]; then
  template="feature.md"
elif [[ "$branch_name" == bugfix/* ]]; then
  template="bugfix.md"
elif [[ "$branch_name" == release/* ]]; then
  template="release.md"
else
  template="feature.md"
fi

# Коміт змін
echo "📦 Комітуємо зміни..."
git add .
git commit -m "🚀 Автокоміт: $branch_name" || echo "⚠️ Немає змін для коміту"

# Пушимо гілку
echo "⬆️ Пушимо гілку на GitHub..."
git push -u origin "$branch_name"

# Отримуємо назву користувача та репозиторію
remote_url=$(git config --get remote.origin.url)

# Підтримка HTTPS і SSH форматів
if [[ "$remote_url" == git@* ]]; then
  user=$(echo "$remote_url" | cut -d':' -f2 | cut -d'/' -f1)
  repo=$(echo "$remote_url" | cut -d'/' -f2 | sed 's/\.git$//')
else
  user=$(echo "$remote_url" | cut -d'/' -f4)
  repo=$(echo "$remote_url" | cut -d'/' -f5 | sed 's/\.git$//')
fi

# Назва PR
title=$(echo "$branch_name" | sed -E 's/^(feature|bugfix|release)\///' | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
body="Автоматичний Pull Request для **$branch_name**"

# Формуємо посилання на PR
url="https://github.com/$user/$repo/compare/$default_branch...$branch_name?quick_pull=1&title=$(echo $title | sed 's/ /%20/g')&body=$(echo $body | sed 's/ /%20/g')&template=$template"

# Відкриваємо в браузері
echo "🔗 Відкриваємо PR у браузері..."
xdg-open "$url" 2>/dev/null || open "$url"
