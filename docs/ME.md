服务器生成激活码：
ssh -p 23421 root@207.56.8.8
cd /opt/starchat
docker compose exec -T business-api \
  python -m app.cli.generate_invitation --created-by server-admin