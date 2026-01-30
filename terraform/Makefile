ENV    ?= $(or $(TARGET_ENV),$(AWS_PROFILE))
TFVARS ?= $(ENV).tfvars
ARGS   ?=

.PHONY: init plan apply fmt validate output secrets

init:
	./scripts/init_backend.sh
	terraform init

plan:
	terraform plan -var-file=$(TFVARS) $(ARGS)

apply:
	terraform apply -var-file=$(TFVARS) $(ARGS)

fmt:
	terraform fmt -recursive

validate:
	terraform validate

output:
	terraform output $(ARGS)

secrets:
	terraform output -json | jq
