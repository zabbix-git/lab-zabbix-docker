# Desafio Técnico

#### Descrição

Documento referente aos procedimentos técnicos e teóricos executados no desafio proposto.

## Sumario

- [1 Customizar Dockerfile](#customizar-dockerfile)
  - [1.1 Healthcheck: Zabbix Frontend](#healthcheck-zabbix-frontend)
  - [1.2 Pollers: Zabbix Server](#pollers-zabbix-server)
  - [1.3 Feature: Alertscripts - Telegram](#feature-alertscripts-telegram)
  - [1.4 Deploy Swarm](#deploy-swarm)
- [2 Monitorando MySQL (LLD + ODBC)](#monitorando-mysql-lld-odbc)
  - [2.1 Configurações e validações iniciais](#configurações-e-validações-iniciais)
  - [2.2 Criação do Template](#criação-do-template)
  - [2.3 Criação de LLD](#criação-de-lld)
  - [2.4 Criação do Host](#criação-do-host)
- [3 Estruturando Demandas](#estruturando-demandas)
- [4 Aplicação WEB](#aplicação-web)
  - [4.1 Frontend](#frontend)
  - [4.2 Backend](#backend)
  - [4.3 Banco de Dados](#banco-de-dados)
- [5 Monitorando YAML](#monitorando-yaml)
- [6 Monitorando Apache HTTPD](#monitorando-apache-httpd)

## **Customizar Dockerfile**
  
### **Healthcheck**: *Zabbix Frontend*
Inserir no arquivo *Dockerfile* do **Zabbix Frontend**:
  ```
  #HEALTHCHECK - ZABBIX-FRONTEND
  HEALTHCHECK --interval=1m --timeout=3s \
    CMD curl -f http://localhost/zabbix || exit 1
  ```

### **Pollers**: *Zabbix Server*
Inserir no arquivo *Dockerfile* do **Zabbix Server**:
  ```
  ENV ZBX_STARTPOLLERS=5
  ENV ZBX_IPMIPOLLERS=0
  ENV ZBX_STARTPOLLERSUNREACHABLE=1
  ENV ZBX_STARTTRAPPERS=5
  ENV ZBX_STARTPINGERS=5
  ENV ZBX_STARTDISCOVERERS=5
  ENV ZBX_STARTHTTPPOLLERS=5
  ENV ZBX_STARTJAVAPOLLERS=0
  ENV ZBX_STARTLLDPROCESSORS=2
  ENV ZBX_STARTVMWARECOLLECTORS=0
  ENV ZBX_STARTPROXYPOLLERS=1
  ```

### **Feature**: *Alertscripts Telegram*
- No Telegram, procurar pelo @BotFather, iniciar conversa, criar **BOT** (/newbot) e configurá-lo (será retornado o *TOKEN*);
- Iniciar conversa com o **BOT** criado e mandar qualquer mensagem;
- Inserir script *"telegram.py"* no diretório do **zabbix server** *"/usr/lib/zabbix/alertscripts"* com **permissão de execução**; 
- Com o *TOKEN* retornado, inserir na variável **BOT_TOKEN=** do script *"telegram.py"*;
- Acessar "api.telegram.org/bot*TOKEN*/getUpdates" e identificar ID do usuário que enviou mensagem;
- Configurar mídia de usuário com o ID;
- Definir qual cenário para execução da ação (envio de mensagem via Telegram).

### **Deploy Swarm**
Baseando-se nos arquivos da branche *"zabbix-docker-compose/docker-compose"*, executar:

Iniciar service:
  ```
  docker stack deploy -c docker-compose.yaml NOME_DO_SERVICE
  ```

Validar service:
  ```
  docker service ps NOME_DO_SERVICE
  ```

## **Monitorando MySQL (LLD + ODBC)**

### Configurações e validações iniciais
Para monitorar via ODBC, vamos precisar de um PROXY.
Após as configurações iniciais e validação do funcionamento do serviço Zabbix Proxy, precisamos instalar alguns pacotes adicionais:
- unixODBC, unixODBC-devel e o mysql-connector-odbc;

Validar o driver **MySQL ODBC 8.0 Unicode Driver** no arquivo *"/etc/odbcinst.ini"* e inserir o conteúdo abaixo em *"/etc/odbc.ini"*:
  ```
  [DSN_NAME]
  Description = MySQL Database
  Driver      = MySQL ODBC 8.0 Unicode Driver
  Server      = IP_DB
  Port        = 3306
  Database    = DATABASE_NAME
  ```
**Detalhes**:
- DSN_NAME: Nome de conexão;
- IP_DB: IP do servidor MySQL;
- DATABASE_NAME: Nome da base de dados.

**No servidor de banco de dados, criar usuário com permissão na database a ser monitorada**.

Validando a conexão:
  ```
  isql -v DSN_NAME USER_BD PASS_USER_DB
  ```
**Detalhes**:
- DSN_NAME: Nome de conexão;
- USER_BD: Usuário criado e configurado previamente no MySQL;
- PASS_USER_DB: Senha do usuário.

Retorno desejado:
  ```
  +---------------------------------------+
  | Connected!                            |
  |                                       |
  | sql-statement                         |
  | help [tablename]                      |
  | quit                                  |
  |                                       |
  +---------------------------------------+
  SQL>
  ```

### **Criação do Template**
Acessar interface Web do Zabbix para criação do Template - *(Configuração > Templates > Criar template)*.
Definir:
- *Nome do template*: Template ODBC MySQL;
- *Grupos*: Templates/Banco de Dados;
- *Macros*
  - **{$MYSQL.USER}**: Usuário criado e configurado previamente no MySQL;
  - **{$MYSQL.PASSWORD}**: Senha do usuário.
**Adicionar**

### **Criação de LLD**
Após criar o template, acessá-lo e *(Regras de Descoberta > Criar regra de descoberta)*
Definir:
- *Nome*: Descoberta de Tabelas
- *Tipo*: monitoração de banco de dados
- *Chave*: db.odbc.discovery[discovery.tables.DATABASE_NAME,{HOST.HOST}]
- *Nome do usuário*: {$MYSQL.USER}
- *Senha*: {$MYSQL.PASSWORD}
- *Pesquisa SQL*: SELECT table_name FROM information_schema.tables WHERE table_schema = 'DATABASE_NAME';
- *Intervalo de atualização*: 31m
**Detalhes**:
- DATABASE_NAME: Nome da base de dados;
- Por boa prática, utilizar números primos em *Intervalo de atualização* (evitando concorrência).
**Adicionar**

Após criar a regra de descoberta, é preciso criar o protótipo do item. Para isso, acessar o template *(Regras de Descoberta > Protótipos de itens > Criar protótipo de item)*
- *Nome*: [{#TABLE_NAME}] Size
- *Tipo*: monitoração de banco de dados
- *Chave*: db.odbc.select[{#TABLE_NAME}.size,{HOST.HOST}]
- *Nome do usuário*: {$MYSQL.USER}
- *Senha*: {$MYSQL.PASSWORD}
- *Pesquisa SQL*: SELECT round((data_length + index_length) / 1024) as 'size' FROM information_schema.tables WHERE table_schema = 'DATABASE_NAME' AND table_name = '{#TABLE_NAME}';
- *Intervalo de atualização*: 7m
- *Tipo de informação*: Numérico (fracionário)
- *Unidades*: B
- *Período de retenção do histórico*: De acordo com a necessidade
- *Período de retenção das estatísticas*: De acordo com a necessidade
- *Novo protótipo de aplicação*: [{#TABLE_NAME}]
**Detalhes**:
- DATABASE_NAME: Nome da base de dados;
- Por boa prática, utilizar números primos em *Intervalo de atualização* (evitando concorrência).
**Adicionar**

### **Criação do Host**
Acessar *(Configuração > Hosts > Criar host)*
- *Nome do host*: DSN_NAME
- *Nome Visível*: Caso queira alterar
- *Grupos*: Banco de Dados
- *Monitorado por proxy*: Selecionar o proxy onde as configurações iniciais foram realizadas

Por fim, associar o template no host e acompanhar a coleta dos dados.

## **Estruturando Demandas**
Na maioria dos casos, a existência de uma documentação do device a ser monitorado é essencial.
Neste caso, buscaria saber sobre as possibilidades para monitorá-lo, sendo as principais (quando não temos a opção de instalação do Zabbix Agent):
* **API** - *consultar por HTTP, scripts python*;
* **SNMP** - *localizar MIB*;
* **CMDLET** - *criação de scripts shell*.

Claramente, a interação com o cliente é muito fundamental, precisamos tentar extrair o máximo de informação. Ele é quem vai ajudar no entendimento do funcionamento deste device para trazer ao Zabbix. Como ele extrai e acompanha as informações do device?
Além disso, em muitas situações como essa, é o cliente que vai listar os itens a serem monitorados, suas criticidades, os cenários de alarme e como recuperar o incidente (para buscarmos a automação).

Em reuniões iniciais buscamos definir a sequência de entregáveis, formando sprints e definindo metas entre elas. 
Com isso, buscamos uma entrega contínua e com prazo pré-determinado (levando em consideração as possíveis dificuldades).

## **Aplicação WEB**
O tipo de monitoração sempre depende da possibilidade ou não de instalação do Zabbix Agent, pois com ele podemos utilizar diversos métodos para a coleta do dado desejado.

### **Frontend**

* **Web Cenários**: Coletar métricas como:
  * Download da página e response time;
  * Status code (validando caracteres na página).

* **HTTP Agent**: Usufruir do server-status para ter o conhecimento geral da saude do Webserver.

* **Zabbix Agent**: Monitorar a execução do serviço (httpd, nginx).

### **Backend**
Validação através da comunicação com o Banco de Dados e a execução de selects para confirmar a inserção de dados na base.

### **Banco de Dados**
Novamente a execução de selects predefinidos é importante, para validar o funcionamento. Adicionalmente, podemos acompanhar a saude do servidor e do banco de dados, rotinas de backup entre outras.

## **Monitorando YAML**

## **Monitorando Apache**: *HTTPD*

Adicionar arquivo *"/etc/httpd/conf.d/serverstatus.conf"*:
  ```
  Listen *:8080

  <VirtualHost *:8080>
      <Location /server-status>
          RewriteEngine Off
          SetHandler server-status
          Allow from all
          Order deny,allow
          Deny from all
      </Location>
  </VirtualHost>
  ```

Reiniciar serviço **httpd**:
```
  systemctl restart httpd
```

Para validar, acesse URL: http://**NAME_OR_IP**:8080/server-status

Após validação, associar template *App Apache by HTTP* no host desejado, definindo o valor das macros:
* **{$APACHE.STATUS.SCHEME}**: http
* **{$APACHE.STATUS.PORT}**: 8080
* **{$APACHE.STATUS.PATH}**: server-status

**Detalhes**:
* Personalizações no template, de acordo com cenário;
* Substituir *NAME_OR_IP* por valor correspondente;
* *STARTHTTPPOLLERS* definido anteriormente.
