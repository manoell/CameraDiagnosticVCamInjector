# CameraDiagnostic + VCamInjector - Projeto de Substituição de Feed de Câmera iOS

## Visão Geral
Este projeto visa desenvolver uma solução para substituição do feed da câmera em iOS, oferecendo a capacidade de injetar imagens, vídeos ou streams em aplicativos que utilizam a câmera do dispositivo.

## Componentes Principais
1. **DiagnosticTweak**: Componente responsável por coletar informações detalhadas sobre o pipeline de processamento da câmera.
2. **VCamInjector**: Componente que implementa a substituição do feed da câmera.

## Estado Atual do Projeto

### Pipeline de Câmera Identificado
- A câmera nativa do iOS usa `AVCaptureSession` com preset "AVCaptureSessionPresetPhoto"
- Os formatos de vídeo variam por câmera:
  - Câmera traseira: 4032x3024 com formato "420f" (YUV/NV12)
  - Câmera frontal: 1920x1080 com formato "420v" (YUV/YV12)
- Taxa de quadros: 3-30 FPS

### Classes-Chave Identificadas
- `CAMCaptureEngine`: Parece ser o gerenciador central da captura de mídia em apps nativos
- `AVCaptureSession`: Coordena o fluxo entre dispositivos de entrada e saídas
- Outputs identificados:
  - `AVCapturePhotoOutput`: Para fotos
  - `CAMCaptureMovieFileOutput`: Para gravação de vídeo
  - `AVCaptureVideoThumbnailOutput`: Para thumbnails
  - `AVCaptureMetadataOutput`: Para metadados

### Descoberta Importante
O app nativo de Câmera do iOS **não** usa o mecanismo padrão de delegate `AVCaptureVideoDataOutputSampleBufferDelegate` para processar frames. O delegate do `AVCaptureVideoDataOutput` é configurado como `<nil>`, indicando um caminho não-padrão de processamento.

### Prováveis Pontos de Injeção

1. **Antes do processamento pela CAMCaptureEngine**
   - Interceptar frames antes que cheguem ao mecanismo de processamento principal

2. **Interceptação de nível baixo**
   - Possível interceptação na camada entre o hardware da câmera e o AVFoundation
   - Substituir o feed em nível de driver/device

3. **Intercepção de Buffer**
   - O formato "420f" (0x34323066) é usado para frames de vídeo
   - A substituição precisa criar buffers deste mesmo formato para compatibilidade

### Abordagem Técnica Recomendada

1. **Adicionar Hooks para CAMCaptureEngine**
   - Investigar métodos internos relacionados à recepção de frames
   - Possíveis métodos: qualquer método relacionado a frames, processamento de imagem

2. **Foco na Substituição de Frames Completa**
   - Não apenas visual, mas substituição que afeta tanto preview quanto outputs

3. **Preservação de Metadados**
   - Manter timing, orientação e outras propriedades ao substituir frames

## Código Base Disponível

- **DiagnosticTweak.xm**: Implementa diagnóstico e registro de eventos
- **DiagnosticExtension.xm**: Implementa diagnóstico avançado do pipeline
- **VCamHook.xm**: Implementa hooks para interceptação de frames
- **VCamInjector.mm**: Implementa a criação de frames substitutos

## Arquivos de Configuração

- Localização: `/var/mobile/Library/Application Support/VCamMJPEG/`
- Arquivo de configuração: `config.plist`
- Imagem padrão: `default.jpg`

## Próximos Passos

1. **Diagnóstico mais profundo da classe CAMCaptureEngine**
2. **Identificação do mecanismo exato usado pelo iOS para processamento de frames**
3. **Implementação da substituição no ponto ideal identificado**

## Requisitos

- iOS 14.0+
- Dispositivo com jailbreak
- Theos para compilação
