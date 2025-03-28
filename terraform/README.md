# Terraform setup

The `terraform` directory contains the necessary files to create the full CDC setup using Terraform. There are a couple of things to note: 
- While the Source & Sink connectors are being successfully created, you will notice that their tasks are failing with an error. This is because there are still some steps we have to complete for them to be able to start properly:
	- Create tables in PostgreSQL & ClickHouse
	- Set the REPLICA IDENTITY in PostgreSQL
	- Install `aiven_extras`
	- Create a publication in PostgreSQL

In order to run the script, go through the usual Terraform steps:
```
terraform init 
```

```
terraform plan -var-file variables.tfvars 
```

```
terraform apply -var-file variables.tfvars 
```
