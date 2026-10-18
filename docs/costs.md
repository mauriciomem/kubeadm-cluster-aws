# Costs

The cluster bills by the hour from `terraform apply` until `terraform destroy` finishes, whether
you use it or not. The figures below are us-east-1 on-demand list prices. Other regions cost
somewhat more, and prices change, so check the AWS pricing pages for EC2, VPC and Elastic Load
Balancing before you rely on them.

## The default cluster

One control plane and two workers:

| Item | Price | Per hour |
|---|---|---|
| 3 t3.medium instances | $0.0416 an hour each | $0.125 |
| NAT gateway | $0.045 an hour | $0.045 |
| Network Load Balancer | $0.0225 an hour, plus about $0.006 for capacity units | $0.029 |
| 4 public IPv4 addresses (the NAT gateway, and the load balancer in 3 AZs) | $0.005 an hour each | $0.020 |
| 3 × 30 GiB gp3 volumes | $0.08 per GiB-month | $0.010 |
| **Total** | | **about $0.23** |

That's about $5.50 a day, or $165 for a month left running.

A new cluster also pulls 2 to 3 GB of packages and images through the NAT gateway, at $0.045
per GB, so each fresh cluster costs about $0.15 extra. The SSM parameter that holds the admin
kubeconfig is an Advanced parameter, at $0.05 a month.

## Other layouts

| Layout | Change | Per hour |
|---|---|---|
| 3 control planes, 2 workers | `control_plane_count = 3` | about $0.32 |
| Single node | `worker_count = 0` | about $0.14 |
| One NAT gateway per AZ | `single_nat_gateway = false` | about $0.10 more |

## Stopping isn't enough

Stopping the instances in the EC2 console only stops the instance charges. The NAT gateway, the
load balancer and the public IPv4 addresses keep billing, about $0.09 an hour together, and the
volumes keep billing too. To stop paying, run `terraform destroy`.
