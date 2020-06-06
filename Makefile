#!make

include .env

AWS = AWS_ACCESS_KEY_ID= AWS_PROFILE=$(AWS_PROFILE) aws
SAM = AWS_ACCESS_KEY_ID= AWS_PROFILE=$(AWS_PROFILE) sam

create-deploy-bucket: check-vars
	@$(AWS) s3 mb s3://$(DEPLOY_BUCKET)

start: check-local-vars
	docker-compose up -d

stop:
	docker-compose down

create-table: check-local-vars
	@echo deleting $(TABLE_NAME)
	-$(AWS) dynamodb delete-table \
		--endpoint-url http://localhost:$(LOCAL_DYNAMODB_PORT) \
    --table-name $(TABLE_NAME)
	$(AWS) dynamodb create-table \
		--endpoint-url http://localhost:$(LOCAL_DYNAMODB_PORT) \
    --table-name $(TABLE_NAME) \
    --attribute-definitions AttributeName=roomId,AttributeType=S AttributeName=connectionId,AttributeType=S \
    --key-schema AttributeName=roomId,KeyType=HASH AttributeName=connectionId,KeyType=RANGE \
    --global-secondary-indexes IndexName=ConnectionIdIndex,KeySchema=["{AttributeName=connectionId,KeyType=HASH}"],Projection={ProjectionType=KEYS_ONLY},ProvisionedThroughput="{ReadCapacityUnits=1,WriteCapacityUnits=1}" \
    --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1

call-%: check-local-vars
	$(SAM) local invoke $(*)Function \
		--parameter-overrides \
				TableName=$(TABLE_NAME) \
				TableTtlHours=$(TABLE_TTL_HOURS) \
				LocalDynamodbEndpoint=$(LOCAL_DYNAMODB_ENDPOINT) \
				AppPrefix=$(STACK_NAME) \
				LogLevel=DEBUG \
				Environment=development \
		--event test/$(eventPrefix)Event.json

test-init:
	make start
	make create-table

test-OnConnect:
	make call-OnConnect eventPrefix=OnConnect

test-OnDisconnect:
	make call-OnDisconnect eventPrefix=OnDisconnect

test-SendMessage:
	make call-SendMessage eventPrefix=SendMessage

test-RoomJoined:
	make call-SendMessage eventPrefix=RoomJoined

test-RoomLeft:
	make call-SendMessage eventPrefix=RoomLeft

test-all: test-init
	make test-OnConnect
	make test-SendMessage
	make test-OnDisconnect
	make test-RoomJoined
	make test-RoomLeft

sam-package: check-vars
	$(SAM) package \
	--template-file template.yaml \
	--output-template-file packaged.yaml \
	--s3-bucket $(DEPLOY_BUCKET)

sam-deploy: check-vars
	$(SAM) deploy \
		--stack-name=$(STACK_NAME) \
		--template-file packaged.yaml \
		--capabilities CAPABILITY_IAM \
		--parameter-overrides \
				TableName=$(TABLE_NAME) \
				TableTtlHours=$(TABLE_TTL_HOURS) \
				WebsiteBucketName=$(WEBSITE_BUCKET) \
				DomainName=$(DOMAIN_NAME) \
				CertificateArn=$(CERTIFICATE_ARN) \
				AppPrefix=$(STACK_NAME) \
				LogLevel=INFO \
				Environment=production \
		--s3-bucket $(DEPLOY_BUCKET)

website-build: check-vars
	rm -rf ./webclient/dist
	cd webclient && yarn build
website-invalidate: check-vars
	$(AWS) cloudfront create-invalidation --distribution-id E2FADU0GBQ8AES --paths "/*"
website-deploy: check-vars website-build
	$(AWS) s3 sync --acl "public-read" ./webclient/dist/ s3://$(WEBSITE_BUCKET)
	make website-invalidate

stack-describe: check-vars
	$(AWS) cloudformation describe-stacks \
		--stack-name=$(STACK_NAME) \
		--query 'Stacks[].Outputs'

stack-deploy:
	make sam-package
	make sam-deploy
	make stack-describe

# Environment variables check
guard-%:
	@ if [ "${${*}}" = "" ]; then \
			echo "Please set $* in your .env file"; \
			exit 1; \
	fi

check-vars:
	@make guard-AWS_PROFILE
	@make guard-STACK_NAME
	@make guard-DEPLOY_BUCKET
	@make guard-TABLE_NAME
	@make guard-TABLE_TTL_HOURS
	@make guard-WEBSITE_BUCKET
	@make guard-DOMAIN_NAME
	@make guard-CERTIFICATE_ARN

check-local-vars:
	@make guard-STACK_NAME
	@make guard-TABLE_NAME
	@make guard-TABLE_TTL_HOURS
	@make guard-LOCAL_DYNAMODB_ENDPOINT
	@make guard-LOCAL_DYNAMODB_PORT


install-qrcode-terminal:
	npm install -g qrcode-terminal

LOCALIP=$(shell ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1)
URL=http://${LOCALIP}:1234
run-local-server:
	@echo '${URL}' | qrcode-terminal
	@cd webclient && yarn start

.PHONY: check-vars check-local-vars sam-package sam-deploy stack-describe
