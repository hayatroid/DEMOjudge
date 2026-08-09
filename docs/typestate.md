# 🧩 Typestate

DEMOjudge はジャッジ 1 回分のライフサイクルを Gleam の [Opaque types](https://tour.gleam.run/advanced-features/opaque-types/) で表している．
Opaque types の値はモジュールの外からはつくれず，公開された関数のみを経由してつくれる．

デモの compiling / running / compile error / completed の各フェーズを開くと，型と，その型の値をつくるための関数が載っている．

![](assets/typestate-compiling.webp)

型と関数の一覧は次の通り．

https://github.com/hayatroid/DEMOjudge/blob/f426125cafd4840219c1a9a07650128fdb7c6e05/src/domain/submission/attempt.gleam#L1-L56

## 参考

- [関数型ドメインモデリング](https://asciidwango.jp/post/754242099814268928/%E9%96%A2%E6%95%B0%E5%9E%8B%E3%83%89%E3%83%A1%E3%82%A4%E3%83%B3%E3%83%A2%E3%83%87%E3%83%AA%E3%83%B3%E3%82%B0) 6.4「ビジネスルールを型システムで表現する」
