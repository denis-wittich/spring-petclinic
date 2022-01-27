# The Graduate Project
This repo contains files of my Gradute Project.

## Description
High-Load Java Application that accepts a set of data from a queue and runs a background job. 
It has a secured WEB UI, that will be used by many customers to see processed data and search. 
State of the completed jobs is stored in RDB but indexed information for a fast search functionality will be stored in NoSQL ElasticSearch:
* Java Application with Search Engine and reading queue service Built-in
* MySQL database
* ElasticSearch Cluster (3x instances)
* Queue service for incoming data (Data will be populated by another application name is XYZ in Project name is CDE )

## GCP Cloud Platform
* Terraform for all services and instances
* Ansible for Configuration Management
* GitHub Actions in Private Terraform and Ansible repo to provision infrustructure