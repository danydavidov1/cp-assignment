output "webhook_url" {
  value = "${aws_api_gateway_stage.prod.invoke_url}${aws_api_gateway_resource.proxy.path}"
}
