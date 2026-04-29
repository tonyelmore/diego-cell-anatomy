# Modern Application Deployment: Kubernetes vs. Tanzu Application Service (TAS)

## Executive Summary
As organizations modernize their software delivery lifecycles, they face a choice between building custom container-based workflows on Kubernetes or utilizing an opinionated platform like Tanzu Application Service (TAS). This document explores the architectural and operational differences between these two approaches, highlighting how TAS reduces cognitive load on development teams by providing a structured, automated path to production.

---

## Process 1: The Kubernetes Deployment Pipeline (Automated via Jenkins)

Deploying software to Kubernetes requires the user to manage the entire artifact creation process. When using a Jenkins pipeline, the developer or DevOps engineer must explicitly define every step of the "Build-Ship-Run" cycle.

### The Jenkins Pipeline Workflow
To get software from Git to a running Kubernetes cluster, a Jenkinsfile must be crafted to handle the following:

1.  **Checkout:** Pull the latest source code from the Git repository.
2.  **Artifact Compilation:** Run language-specific build tools (e.g., Maven for Java, NPM for Node.js) to create a binary.
3.  **Containerization (Docker Build):**
    * The user must maintain a `Dockerfile`.
    * The pipeline executes `docker build`, layering the application on top of a Base OS image (e.g., Alpine, Ubuntu).
    * **User Responsibility:** The user selects the base image and manages all system libraries.
4.  **Image Tagging & Push:** The pipeline authenticates with a Container Registry and pushes the image.
5.  **Manifest Preparation:** The pipeline updates Kubernetes YAML files (Deployments, Services, Ingress) with the new image tag.
6.  **Deployment:** Execute `kubectl apply` to trigger the update in the Kubernetes cluster.

---

## Process 2: The Tanzu Application Service Workflow

In TAS, the system abstracts away the complexity of container construction. Instead of building an image, the developer provides the source code, and the platform handles the rest through "staging."

### How the Pieces Fit Together
* **Source Code:** The raw code in the Git repository.
* **Package:** When a user runs `cf push`, the source code is zipped into a package and uploaded.
* **Buildpack:** The "compiler" for the platform. It automatically detects the language, provides the runtime (e.g., JRE), and handles dependencies.
* **Stack:** The root filesystem (RootFS) that provides the OS libraries. This is a curated, hardened layer maintained by platform operators.
* **Droplet:** The final execution unit. It is a combination of the compiled application and the buildpack's output.

### The Absence of a "Container Runtime"
Unlike Kubernetes, where the user builds the entire runtime environment into an image, TAS separates the application (Droplet) from the Operating System (Stack). 

**Crucial Distinction:** The Droplet is **not** equivalent to a container image because it does not contain the OS runtime; that is provided by the Stack at the moment the container is created to start running the application. Therefore, there is no user-managed "container runtime" in a TAS environment.

---

## Operational Simplicity: Networking and Certificates

A significant advantage of the TAS opinionated approach is its management of the application edge. TAS manages all certificates and provides a built-in router. This means that application teams do not have to concern themselves with:
* **DNS Management:** Routes are automatically assigned or mapped by the platform.
* **Load Balancers:** Traffic is managed by the internal TAS GoRouter.
* **Certificate Management:** SSL/TLS termination is handled by the platform, removing the need for teams to manage individual cert renewals or secrets.

---

## Process Comparison: Pros and Cons

| Feature | Kubernetes (DIY) | Tanzu Application Service (Opinionated) |
| :--- | :--- | :--- |
| **Developer Focus** | High (must manage Dockerfiles, YAML, OS) | Low (focuses only on code) |
| **Consistency** | Low (every team uses different base images) | High (standardized buildpacks and stacks) |
| **Security** | Manual (User must patch base images) | Automated (Platform patches the Stack) |
| **Networking** | Complex (User manages Ingress/Certs/LB) | Simple (Platform manages Router/Certs) |

### The Case for TAS: Offloading Developer Toil
The primary benefit of TAS is **offloading work from development teams**. By using an opinionated platform, developers do not need to become experts in Linux distributions, container orchestration, or networking infrastructure. The platform provides a "contract": give us the code, and the platform ensures it runs securely and is accessible.

---

## Security and Vulnerability Scanning

Scanning for vulnerabilities differs significantly between the two platforms.

### Kubernetes Scanning
In Kubernetes, the **Container Image** is built up front by the user with libraries they choose. 
* **Process:** A scanner must scan the entire image (Base OS + App + Libraries).
* **Workload:** If a library vulnerability is found in the OS layer, the developer must manually update the Dockerfile, rebuild, and re-deploy.

### TAS Scanning (Efficiency through Immutability)
In TAS, the components are scanned individually, creating a more efficient model:
1.  **Source Code/Package:** Scanned using Static Application Security Testing (SAST) tools, similar to Kubernetes.
2.  **Buildpacks and Stacks:** These are curated, immutable sets of libraries provided by the platform vendor or operators. They are scanned **once** at the platform level. Because they are immutable to the user, they remain secure throughout the lifecycle.
3.  **The Droplet:** Scanning the Droplet provides **no value**. Since the package (source code) and buildpacks have been individually scanned and are immutable, the resulting Droplet is already verified. 

**Note:** The Droplet is not equivalent to a container runtime because it lacks the OS runtime provided by the stack, further simplifying the scan surface area and reducing redundant work.

---

## Conclusion
The fundamental difference lies in the **boundary of responsibility**. Kubernetes requires developers to be "full-stack" from the OS up through networking. Tanzu Application Service creates a clear separation, allowing developers to remain focused on business logic while the platform handles the complexities of the runtime environment, networking, and security patching.