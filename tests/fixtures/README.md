# Origem das amostras de teste

Estas amostras são dependências de `tests/Test-RelatorioDell.ps1`. Não são necessárias para executar o relatório em um servidor e não são relatórios de uma consulta atual.

## Inventario-R530.txt

Baseado no texto de uma execução real de `DSU.exe --inventory`, versão 1.9.2.0, em um PowerEdge R530, fornecido pelo operador em 28/10/2026. O preâmbulo foi resumido; os 25 registros, seus nomes, tipos e versões foram preservados. O arquivo termina com `Exiting DSU!`.

O nome da máquina foi removido do nome do arquivo, e os testes usam `SRV-EXEMPLO`/`TESTE` como hostname/Service Tag fictícios. O texto do fixture não contém a Service Tag real. Os dados de hardware e versões mantêm o caso de regressão que revelou as pendências de BIOS e PERC e as limitações dos registros genéricos.

## dell-r530-resumo.json

Recorte de seis registros retornados pela interface interna de downloads do site oficial Dell, consultada em 28/10/2026 com `productcode=poweredge-r530` e `oscode=W12R2`. A resposta integral tinha 352 registros.

Foram mantidos campos necessários aos testes: identidade/título/tipo do pacote, criticidade textual, data, versão, categoria, nomes/tipos de arquivos e códigos de SO. Campos e descrições não usados foram removidos; `AppOses` teve duplicatas removidas. Portanto, o fixture é uma **amostra reduzida de dados reais**, não uma cópia integral da resposta e não uma previsão de todos os downloads atuais.

| DriverId | Uso na regressão | Referência Dell |
| --- | --- | --- |
| PVDNH | BIOS 2.19.0 | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=pvdnh) |
| VWF72 | iDRAC 2.86.86.86 | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=vwf72) |
| 89DRR | Referência antiga de iDRAC, para conferir escolha pela data | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=89drr) |
| 700GG | Firmware PERC 25.5.9.0001 | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=700gg) |
| DFF48 | Firmware Broadcom, preservado como inconclusivo sem identificação suficiente | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=dff48) |
| CN7MV | Driver Broadcom; versão zero no inventário não é comparada | [Página do pacote](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=cn7mv) |

A proveniência da consulta, URLs e hashes dos JavaScripts examinados estão em [docs/evidencias/api-dell-2026-10-28.json](../../docs/evidencias/api-dell-2026-10-28.json). As condições e os limites da API estão documentados no [README principal](../../README.md).

Alterações na resposta online não devem mudar silenciosamente estes fixtures. Para atualizá-los, registre uma nova coleta, preserve a origem e confira se as expectativas dos testes continuam corretas.

## Casos por Service Tag

Os campos `IsTag`, `ServiceTag`, `IsNoDriversFoundForTag` e `IsTagDriver` usados nos novos testes são **sintéticos**, acrescentados em memória pelo harness. A tag `ABC1234` e o identificador `0-TOKEN_SINTETICO_1234567890` são exemplos fictícios. Não representam uma consulta real por tag nem uma contagem validada online.

A seleção `IsTagDriver > 0` e o uso de `encryptedServiceTag` foram observados no JavaScript oficial da Dell. A tentativa de acesso online à página de uma tag real recebeu HTTP 403 neste ambiente; a evidência está em [docs/evidencias/api-dell-service-tag-2026-10-28.json](../../docs/evidencias/api-dell-service-tag-2026-10-28.json). Nenhuma tag real ou seu identificador foi incorporado aos arquivos de teste.
