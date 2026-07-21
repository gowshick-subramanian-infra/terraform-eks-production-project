output "alb_sg_id" {
  value = aws_security_group.alb.id
}

output "eks_nodes_sg_id" {
  value = aws_security_group.eks_nodes.id
}

output "eks_cluster_sg_id" {
  value = aws_security_group.eks_cluster.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "bastion_sg_id" {
  value = length(aws_security_group.bastion) > 0 ? aws_security_group.bastion[0].id : null
}
