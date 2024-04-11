# 1BRC-zig

O 1BRC: https://github.com/gunnarmorling/1brc/.

> The One Billion Row Challenge (1BRC) is a fun exploration of how far modern Java can be pushed for aggregating one billion rows from a text file. 
> Grab all your (virtual) threads, reach out to SIMD, optimize your GC, or pull any other trick, and create the fastest implementation for solving this task!


## Como executar

- Baixe seu binário do zig [aqui!](https://ziglang.org/download/).
     - Estou usando a versão `0.11.0`

- Dentro do repositório, rode `zig build -Doptimize=ReleaseFast` para buildar.

- Caso ainda não o tenha, use o o binário `run-create-sample` para criar seu arquivo TXT com 1 bilhão de linhas **(~12GB)**: `./zig-out/bin/run-create-sample 1000000000` *(Isso deve levar de 3 a 5 minutos)*

- Pronto! Agora execute `time ./zig-out/bin/1brc-zig measurements.txt` e veja seu tempo!

> Utilizar um cache fresco é permitido pelo desafio. Rode o teste duas vezes para ter um melhor desempenho: `(cd zig-out/bin && .1brc-zig && time ./1brc-zig)`

## Benchmarks

Asus Zenbook 14 ux435, com Core i7-1165G7, 8gb LPDDR4X e SSD NVME PCIe 3.0 (Fedora 39, linux 6.8.4): **11.98 segundos**
```
37.90s user 4.74s system 355% cpu 11.983 total
```

Desktop com Ryzen 5 3600, 16gb DDR4 @ 2600mhz e SSD NVME (Fedora 39, linux 6.7.7): **4.63 segundos**
```
40.42s user 1.42s system 903% cpu 4.631 total
```

> Ao contrário do que parece, a quantidade de memória RAM não importa. O principal fator para melhor o desempenho é a quantidade de threads do seu processador.
