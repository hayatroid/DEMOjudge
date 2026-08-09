# 💥 Fault Injection

DEMOjudge は障害を注入できる．
デモの phases の compiling と running にはボタンが付いていて，押しておくと，そのフェーズにいるノードが止まる．

AWS 上では，FIS (Fault Injection Service) がインスタンスを停止し，2 分後に立ち上げ直す．
現実でいうところの，2 分間の停電である．

https://github.com/hayatroid/DEMOjudge/blob/f426125cafd4840219c1a9a07650128fdb7c6e05/aws/main.tf#L409-L445

## Retry

ジャッジ中のノードが故障すると，その提出は queued に戻り，他のノードが引き継ぐ．
引き継いだノードは，ジャッジを最初からやり直す．

![](assets/fault-injection-retry.webp)

## Escalate

ジャッジ中のノードが故障して他のノードが引き継ぐことを 3 回繰り返すと，その提出はエスカレーションされる．
エスカレーションされた提出は，解決されるまで queued に戻らない．

![](assets/fault-injection-escalate.webp)

## 参考

- [AWS Fault Injection Service](https://aws.amazon.com/fis/)
