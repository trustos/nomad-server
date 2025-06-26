namespace "*" {
  policy = "write"
}

host_volume "*" {
  policy = "write"
}

volume "*" {
  policy = "write"
}

node {
  policy = "read"
}

agent {
  policy = "read"
}
