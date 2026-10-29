# Importar os downloads Dell salvos do navegador

Este modo permite que o analista abra normalmente o site Dell, pesquise o servidor pela Service Tag e entregue ao script um **arquivo HAR sanitizado (`.har`)**. Não exige extensão, copiar atualização por atualização ou baixar os pacotes. O parâmetro é `-ArquivoSiteDell`.

O HAR é um arquivo de texto estruturado que registra as solicitações e respostas observadas na guia Rede do navegador. O script usa apenas a resposta de downloads compatível com o modelo e o Windows do servidor. Essa leitura local substitui a consulta HTTP do relatório; as regras de comparação com o inventário continuam as mesmas.

## O que você precisa entregar

Entregue **um HAR com o corpo da resposta de downloads da Dell**, capturado enquanto a lista carrega. Ele deve corresponder ao **modelo e sistema operacional do servidor que será analisado**. O script obtém do arquivo, automaticamente:

| Informação | Origem na captura |
| --- | --- |
| Modelo/produto e SO usados na pesquisa | Parâmetros da solicitação de downloads, como `productcode` e `oscode` |
| Identificador e nome de cada atualização | `DriverId` e `DriverName` da resposta |
| Tipo e categoria | `Type` e os campos de categoria, como `CatName` |
| Versão publicada | `DellVer` |
| Criticidade | `Imp`, como Urgent, Recommended ou Optional, ou as traduções correspondentes |
| Data de lançamento | `ReleaseDate` |
| Nome e formato do pacote | `FileFrmtInfo` e `OthFileFrmts` |

Você não precisa editar esses campos. Hostname, tag, modelo e Windows do servidor são lidos localmente; os componentes e as versões instaladas vêm do DSU ou de `-ArquivoInventario`. Uma captura de downloads não substitui o inventário instalado.

**Não servem para essa importação:** print, PDF, HTML salvo com `Ctrl+S`, lista copiada da tela ou arquivo produzido por **Download Selected**. O HTML pode não incluir os dados carregados separadamente; a tabela visível também pode mostrar apenas parte dos registros. Não é necessário marcar as caixas dos downloads.

## Como salvar pelo Edge ou Chrome

1. Abra o site de suporte Dell e pesquise pela **Service Tag do servidor**. Entre em **Drivers & Downloads / Drivers e downloads**.
2. Selecione o **Windows Server realmente instalado**. Deixe palavra-chave vazia, categoria **All/Todas** e data **All/Todas**. Na imagem de referência, o filtro está em Windows Server 2012 R2; para analisar um servidor Windows Server 2016, altere para 2016 antes de exportar.
3. Pressione **F12** e selecione **Network/Rede** nas ferramentas do navegador. Não há complemento a instalar.
4. Limpe os registros da guia Rede, confira que a gravação está ativa e marque **Disable cache/Desabilitar cache** enquanto as ferramentas estiverem abertas.
5. Recarregue a página com **Ctrl+R** e aguarde a lista de atualizações terminar de carregar. Confira novamente o SO selecionado. Se a página voltou para outro SO, selecione o correto com a guia Rede aberta e aguarde o carregamento. Não clique para baixar os pacotes.
6. Na barra da guia Rede, clique em **Export HAR (sanitized) / Exportar HAR sanitizado** e salve como `DownloadsDell.har`. Os nomes podem variar conforme idioma e versão. Use o HAR sanitizado normal; não é necessário habilitar exportação com dados sensíveis.
7. Copie o `.har` para uma pasta do servidor alvo ou para um compartilhamento acessível por ele.

O registro precisa começar **antes** do carregamento da lista. Se as ferramentas foram abertas apenas depois de tudo carregar, recarregue a página com a guia Rede aberta. Em versões antigas, a opção pode aparecer como **Save all as HAR with content**. O requisito é que o arquivo inclua o corpo da resposta; exportar apenas nomes/URLs das solicitações não basta.

A Microsoft e o Google documentam a exportação na [referência de rede do Edge](https://learn.microsoft.com/en-us/microsoft-edge/devtools/network/reference#save-all-network-requests-to-a-har-file) e na [referência de rede do Chrome](https://developer.chrome.com/docs/devtools/network/reference/#save-all-network-requests-to-a-har-file). A sanitização remove determinados cabeçalhos, mas não garante anonimização de URLs e corpos de resposta.

## Como executar

Abra o Windows PowerShell 5.1 **como administrador**, na pasta do script, e execute:

```powershell
.\Gerar-RelatorioDell.ps1 -ArquivoSiteDell 'C:\Dell\DownloadsDell.har'
```

O padrão continua sendo `-Fonte Site -ConsultaSite Modelo`. O script lê a referência local e coleta o inventário com o DSU. Para reutilizar um inventário já concluído **no mesmo servidor**:

```powershell
.\Gerar-RelatorioDell.ps1 -ArquivoSiteDell 'C:\Dell\DownloadsDell.har' -ArquivoInventario "$env:TEMP\InventarioDell.txt"
```

O arquivo de inventário precisa conter `Exiting DSU!`. Para definir a pasta de relatórios, acrescente `-CaminhoSaida 'C:\RelatoriosDell'` ou o caminho UNC desejado. Não combine `-ArquivoSiteDell` com `-Catalogo` ou `-Fonte Catalogo`: isso gera erro.

O script não refaz a consulta de downloads ao site quando o HAR foi informado. O próprio DSU pode usar a rede para obter seu coletor de inventário; com inventário importado, essa nova coleta não é necessária.

## O que significa abrir a página pela Service Tag

Na imagem de referência, a página identifica uma tag, mas a aba de downloads diz **All PowerEdge R530**. Isso é a lista ampla do modelo, não comprovação de que cada pacote se aplica ao hardware atual. O script mantém o inventário e a comparação local para analisar os candidatos.

Com `-ConsultaSite Modelo`, que é o padrão, o importador usa a lista ampla e registra o escopo **Modelo**, independentemente de a requisição salva se chamar `packdriversbyproduct` ou `packdriversbytag`. Não declara que o conjunto foi validado pela tag.

A opção manual estrita é:

```powershell
.\Gerar-RelatorioDell.ps1 -ArquivoSiteDell 'C:\Dell\DownloadsDell.har' -ConsultaSite ServiceTag
```

Ela exige que a resposta confirme `IsTag`, forneça **a Service Tag em texto claro igual à tag lida do BIOS** e contenha registros válidos com `IsTagDriver > 0`. Apenas um identificador opaco, mesmo igual ao usado na URL, não comprova a identidade do servidor. Se a Dell fornecer somente esse identificador, ou não houver dados de tag confirmados, o modo estrito falha e orienta a escolha explícita de `Modelo`. Não ocorre troca automática.

Esse filtro também não substitui o inventário do hardware atual: um componente pode ter sido trocado desde a configuração original. As limitações de associação e cobertura do [README](../README.md#2-como-funciona-a-engine) continuam valendo.

## Validações e erros

O importador não executa código da página, não segue URLs do HAR e não baixa pacotes. Ele lê as entradas locais, reconhece a resposta Dell, confere produto e SO e trata a resposta em texto ou base64, incluindo a transformação de letras usada pela interface Dell.

| Situação | Como proceder |
| --- | --- |
| HAR inválido, truncado ou sem resposta de downloads | Refaça a captura desde antes do carregamento; não renomeie HTML/JSON para `.har`. |
| Corpo da resposta ausente ou vazio | Grave com a guia Rede aberta, desabilite cache e recarregue; exporte com o conteúdo das respostas. |
| Arquivo acima de 100 MiB | Limpe a guia Rede e capture apenas a página Dell desejada, evitando navegação adicional antes de exportar. |
| Produto ou SO diferente do servidor | Pesquise o equipamento correto, selecione o Windows instalado e exporte novamente. |
| Respostas conflitantes para o mesmo contexto | Limpe a guia Rede, recarregue somente a consulta desejada e gere uma nova captura. |
| Lista vazia, esquema desconhecido ou metadados inválidos | A captura não permite concluir ausência de pendências. Refaça a coleta; se persistir, revise o formato com os arquivos de diagnóstico. |
| Tag estrita sem identidade clara correspondente | Escolha conscientemente `-ConsultaSite Modelo` para usar a lista ampla, ou obtenha uma captura que comprove a tag. |

Falhas de importação não são convertidas em “Nenhuma atualização pendente” e não causam uma consulta HTTP automática como substituição.

## Diagnóstico, privacidade e validação real

O diagnóstico guarda os downloads normalizados e os metadados de importação, incluindo caminho do arquivo local, SHA256, data/hora e contagem. Não copia o HAR completo, cookies ou os demais registros de navegação. Preserve o original nos arquivos operacionais do cliente se precisar refazer a análise; não o publique nem o adicione ao repositório.

O HAR sanitizado pode continuar contendo a Service Tag, identificadores opacos, URLs e dados de resposta. “Sanitizado” não significa “anônimo”. Não são necessárias credenciais, cookies ou arquivos de sessão para a leitura local.

Os testes automatizados usam capturas sintetizadas e verificam seleção e rejeição de entradas inadequadas. **Ainda não foi fornecida uma captura HAR real do navegador do usuário para validar esta alternativa de ponta a ponta.** A primeira execução deve conferir o produto, SO e escopo registrados, o encerramento bem-sucedido no log e alguns pacotes do CSV contra a página Dell. Uma contagem de downloads não é uma contagem de atualizações pendentes.
