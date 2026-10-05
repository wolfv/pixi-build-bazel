#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

int main() {
  const char* prefix = std::getenv("CONDA_PREFIX");
  std::string path = std::string(prefix ? prefix : ".") + "/share/hello/greeting.txt";
  std::ifstream in(path);
  std::string greeting;
  if (!std::getline(in, greeting)) {
    std::cerr << "could not read " << path << "\n";
    return 1;
  }
  std::cout << greeting << std::endl;
  return 0;
}
