#!/bin/bash
# Ручной скрипт для настройки базы данных в Railway
# Используйте этот скрипт, если основной скрипт не работает

set -e

echo "=========================================="
echo "Ручная настройка базы данных"
echo "=========================================="
echo ""

# Проверка DATABASE_URL
if [ -z "$DATABASE_URL" ]; then
    echo "❌ ОШИБКА: DATABASE_URL не установлен!"
    echo ""
    echo "Это нормально, если вы запускаете скрипт локально."
    echo "Переменные Railway доступны только:"
    echo "  1. Через 'railway run' команду"
    echo "  2. В Railway Shell (веб-интерфейс)"
    echo ""
    echo "Для настройки базы данных используйте:"
    echo "  railway run bash scripts/setup-db-manual.sh"
    echo ""
    echo "Или откройте Railway Shell и выполните:"
    echo "  bash scripts/setup-db-manual.sh"
    echo ""
    echo "Убедитесь, что PostgreSQL сервис добавлен в Railway"
    exit 1
fi

echo "✓ DATABASE_URL установлен"
echo ""

# Переход в папку server
cd server || {
    echo "❌ ОШИБКА: Не удалось перейти в папку server"
    exit 1
}

echo "Шаг 1: Генерация Prisma Client..."
export CHECKPOINT_DISABLE=1
npx prisma generate --schema=./prisma/schema.prisma

if [ $? -ne 0 ]; then
    echo "❌ ОШИБКА: Не удалось сгенерировать Prisma Client"
    exit 1
fi

echo "✓ Prisma Client сгенерирован"
echo ""

echo "Шаг 2: Применение схемы к базе данных..."
npx prisma db push --schema=./prisma/schema.prisma --accept-data-loss --skip-generate

if [ $? -ne 0 ]; then
    echo "❌ ОШИБКА: Не удалось применить схему"
    exit 1
fi

echo "✓ Схема применена"
echo ""

echo "Шаг 3: Выполнение миграций..."
npx prisma migrate deploy --schema=./prisma/schema.prisma || {
    echo "⚠️  Предупреждение: Миграции не выполнены (это нормально, если схема уже применена)"
}

echo ""
echo "=========================================="
echo "✅ База данных настроена!"
echo "=========================================="
