# 🚀 Getting Started

> [!CAUTION]
> インフラ (`aws/`, `bin/`) はデモ用の雑な構成です．遊び終わったらすぐ `terraform -chdir=aws destroy` してください．

## Local

サーバ 1 プロセスと DynamoDB Local だけが立ちます．
nix と docker と aws コマンドが必要です．

```sh
nix develop
bin/local
```

ログイン用の URL が表示されるので入ります．
遊び終わったら `Ctrl-C` で止め，`docker rm -f oj-ddb` でストアを消します．

## AWS

EC2 (control 1 台 + worker 2 台) と DynamoDB と付随するリソースが立ちます．
ノード同士は直接通信せず，DynamoDB を介してやり取りします．
terraform と aws コマンドが別途必要です．

```sh
nix develop
export AWS_PROFILE=<ログインするプロファイル>
aws sso login
bin/ready
```

後続のコマンドが表示されるので実行します．

```sh
bin/ship
terraform -chdir=aws init
terraform -chdir=aws apply
api=$(terraform -chdir=aws output -raw api_url)
until curl -sf "$api/" > /dev/null; do sleep 10; done
echo "$api/login?token=$(terraform -chdir=aws output -raw token)"
```

ログイン用の URL が表示されるので入ります．
遊び終わったら `terraform -chdir=aws destroy` で片付けます．
