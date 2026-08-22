.PHONY: help up down logs ps validate clean

help:
	@echo "up        start the full stack"
	@echo "down      stop it, keep the data"
	@echo "clean     stop it and DELETE the volumes"
	@echo "logs      follow all logs"
	@echo "ps        what is running"
	@echo "validate  check every pipeline is actually flowing"

up:
	@test -f .env || cp .env.example .env
	docker compose up -d
	@echo "grafana      http://localhost:3000"
	@echo "prometheus   http://localhost:9090"
	@echo "alertmanager http://localhost:9093"

down:
	docker compose down

clean:
	docker compose down -v

logs:
	docker compose logs -f

ps:
	docker compose ps

validate:
	@./validate.sh
